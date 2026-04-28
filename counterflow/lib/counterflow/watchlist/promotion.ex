defmodule Counterflow.Watchlist.Promotion do
  @moduledoc """
  Universe-wide watchlist scoring. Combines:

    * 1h liquidation notional vs 30d hourly average (the cascade signal)
    * abs(latest funding rate) ranked (positioning extreme)

  Both metrics come from data we already collect for the entire futures
  universe (`!forceOrder@arr` firehose + `/fapi/v1/premiumIndex` poller),
  so we can rank non-watchlist symbols without new ingestion.

  Returns a sorted candidate list, highest-score first, with the reason
  attached so the UI can show *why* a symbol made the cut.
  """

  import Ecto.Query

  alias Counterflow.Repo
  alias Counterflow.Market.{Liquidation, FundingRate, WatchlistEntry}

  @hour_seconds 3600

  @type candidate :: %{
          symbol: String.t(),
          score: float(),
          reason: String.t(),
          liq_notional_1h: float(),
          funding_rate: float()
        }

  @doc """
  Score the universe and return a list of candidates outside the
  current watchlist, ranked by composite score.
  """
  @spec rank_candidates(keyword()) :: [candidate()]
  def rank_candidates(opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)
    watchlist = MapSet.new(Repo.all(from w in WatchlistEntry, select: w.symbol))

    liq = liquidation_scores()
    funding = funding_scores()

    (Map.keys(liq) ++ Map.keys(funding))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(watchlist, &1))
    |> Enum.map(fn sym ->
      build_candidate(sym, Map.get(liq, sym, default_liq()), Map.get(funding, sym, default_funding()))
    end)
    |> Enum.reject(&(&1.score == 0.0))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @doc """
  For demotion: rank current non-pinned watchlist symbols by how "quiet"
  they've been over the last `quiet_window_minutes`. The lowest-scoring
  N are returned for potential demotion.
  """
  @spec rank_quiet(keyword()) :: [String.t()]
  def rank_quiet(opts \\ []) do
    minutes = Keyword.get(opts, :quiet_window_minutes, 60 * 24)
    cutoff = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

    candidates =
      Repo.all(
        from w in WatchlistEntry,
          where: w.pinned == false and (is_nil(w.last_active_at) or w.last_active_at < ^cutoff),
          order_by: [asc: w.last_active_at],
          select: w.symbol
      )

    candidates
  end

  # ── scoring components ──────────────────────────────────────

  defp liquidation_scores do
    one_hour_ago = DateTime.add(DateTime.utc_now(), -@hour_seconds, :second)

    Repo.all(
      from l in Liquidation,
        where: l.time > ^one_hour_ago,
        group_by: l.symbol,
        select: {l.symbol, sum(fragment("? * ?", l.price, l.qty))}
    )
    |> Map.new(fn {sym, notional} -> {sym, %{liq_notional_1h: to_float(notional)}} end)
  end

  defp funding_scores do
    cutoff = DateTime.add(DateTime.utc_now(), -90, :second)

    Repo.all(
      from f in FundingRate,
        where: f.time > ^cutoff,
        distinct: f.symbol,
        order_by: [asc: f.symbol, desc: f.time],
        select: {f.symbol, f.funding_rate}
    )
    |> Map.new(fn {sym, rate} -> {sym, %{funding_rate: to_float(rate)}} end)
  end

  defp build_candidate(sym, liq, funding) do
    liq_notional = liq.liq_notional_1h
    funding_rate = funding.funding_rate
    funding_abs = abs(funding_rate)

    # log-scale on liquidation notional (orders of magnitude vary widely)
    liq_score =
      if liq_notional > 0 do
        :math.log10(liq_notional + 1) / 8.0
      else
        0.0
      end

    # funding gets weight only when extreme (|rate| > 0.05% per 8h)
    funding_score =
      cond do
        funding_abs > 0.001 -> min(funding_abs * 200, 1.0)
        true -> 0.0
      end

    score = 0.6 * liq_score + 0.4 * funding_score

    %{
      symbol: sym,
      score: Float.round(score, 4),
      reason: build_reason(liq_notional, funding_rate),
      liq_notional_1h: liq_notional,
      funding_rate: funding_rate
    }
  end

  defp build_reason(liq, funding) when liq > 100_000 and abs(funding) > 0.001 do
    "liq_cascade + funding_extreme"
  end

  defp build_reason(liq, _funding) when liq > 100_000, do: "liq_cascade"
  defp build_reason(_liq, funding) when abs(funding) > 0.001, do: "funding_extreme"
  defp build_reason(_, _), do: "low_activity"

  defp default_liq, do: %{liq_notional_1h: 0.0}
  defp default_funding, do: %{funding_rate: 0.0}

  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n / 1
end
