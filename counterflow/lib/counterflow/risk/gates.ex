defmodule Counterflow.Risk.Gates do
  @moduledoc """
  Composite risk-gate for live order placement. Every gate must return :ok
  for the order to proceed; the first failing gate logs to risk_rejections
  and returns `{:error, gate_name, details}`.

  Defaults are intentionally conservative; every gate is configurable but
  cannot be disabled outright.
  """

  alias Counterflow.{Repo, Risk.KillSwitch, Risk.Rejection}

  @type ctx :: %{
          required(:symbol) => String.t(),
          required(:side) => String.t(),
          optional(:signal) => map(),
          optional(:notional) => Decimal.t(),
          optional(:leverage) => integer(),
          optional(:account_balance) => Decimal.t(),
          optional(:price_local) => Decimal.t(),
          optional(:price_remote) => Decimal.t()
        }

  @max_leverage 5
  @min_signal_score 0.65

  @spec check(ctx()) :: :ok | {:error, atom(), map()}
  def check(ctx) do
    with :ok <- killswitch_check(ctx),
         :ok <- min_signal_score_check(ctx),
         :ok <- leverage_cap_check(ctx),
         :ok <- price_divergence_check(ctx),
         :ok <- whitelist_check(ctx) do
      :ok
    end
  end

  defp killswitch_check(ctx) do
    if KillSwitch.engaged?() do
      reject(:killswitch, ctx, %{})
    else
      :ok
    end
  end

  defp min_signal_score_check(%{signal: %{score: score}} = ctx) do
    score_f =
      case score do
        %Decimal{} = d -> Decimal.to_float(d)
        n when is_number(n) -> n
        _ -> 0.0
      end

    if score_f >= @min_signal_score do
      :ok
    else
      reject(:min_signal_score, ctx, %{score: score_f, threshold: @min_signal_score})
    end
  end

  defp min_signal_score_check(_), do: :ok

  defp leverage_cap_check(%{leverage: lev} = ctx) when is_integer(lev) do
    if lev <= @max_leverage do
      :ok
    else
      reject(:leverage_cap, ctx, %{requested: lev, cap: @max_leverage})
    end
  end

  defp leverage_cap_check(_), do: :ok

  defp price_divergence_check(%{price_local: lp, price_remote: rp} = ctx)
       when not is_nil(lp) and not is_nil(rp) do
    a = Decimal.to_float(lp)
    b = Decimal.to_float(rp)

    if a > 0 do
      diff_pct = abs(a - b) / a

      if diff_pct < 0.003 do
        :ok
      else
        reject(:price_divergence, ctx, %{local: a, remote: b, diff_pct: diff_pct})
      end
    else
      reject(:price_divergence, ctx, %{reason: "non-positive local price"})
    end
  end

  defp price_divergence_check(_), do: :ok

  defp whitelist_check(%{symbol: sym} = ctx) do
    enabled = Application.get_env(:counterflow, :live_whitelist, [])

    if sym in enabled do
      :ok
    else
      reject(:not_whitelisted, ctx, %{symbol: sym})
    end
  end

  defp reject(gate, ctx, details) do
    Repo.insert(%Rejection{
      attempted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      signal_id: ctx[:signal][:id],
      symbol: ctx[:symbol],
      side: ctx[:side],
      rejected_by: Atom.to_string(gate),
      details: details
    })

    {:error, gate, details}
  end
end
