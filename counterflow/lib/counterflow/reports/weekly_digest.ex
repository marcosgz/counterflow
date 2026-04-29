defmodule Counterflow.Reports.WeeklyDigest do
  @moduledoc """
  Weekly digest report. Aggregates the past 7 days of activity into a
  structured context, asks the configured LLM to write a concise plain-
  English summary, and posts it via the Telegram sink.

  Usage:
      Counterflow.Reports.WeeklyDigest.generate()       # build text only
      Counterflow.Reports.WeeklyDigest.send_now()        # build + post
      Counterflow.Reports.WeeklyDigest.context()         # raw stats only
  """

  import Ecto.Query
  require Logger

  alias Counterflow.{Repo, LLM}
  alias Counterflow.Strategy.Signal
  alias Counterflow.Broker.{PaperFill, PaperPosition}
  alias Counterflow.Risk.{KillswitchEvent, Rejection}
  alias Counterflow.Market.WatchlistEntry

  @lookback_days 7

  @system_prompt """
  You are an assistant for a crypto futures trading dashboard. You receive
  a structured weekly report of an algorithmic strategy's autonomous
  activity and you write a concise, technically literate digest for an
  experienced trader. Use plain-text Markdown that renders well in
  Telegram (no HTML, no code fences for prose). Lead with the punch line.
  Quote concrete numbers. Highlight what changed week-over-week. Flag any
  red flags: high SL rate, runaway drawdown, lopsided win/loss by symbol.
  Keep it under 350 words.
  """

  @doc """
  Build a structured map of all the data points we want the LLM to see.
  Useful as a debugging endpoint; never sent over the wire.
  """
  def context(opts \\ []) do
    days = Keyword.get(opts, :days, @lookback_days)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    %{
      window_days: days,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      signals: signal_stats(cutoff),
      paper: paper_stats(cutoff),
      auto_tune: auto_tune_stats(cutoff),
      watchlist: watchlist_stats(cutoff),
      risk: risk_stats(cutoff),
      top_symbols: top_symbols(cutoff)
    }
  end

  @doc "Generate the digest text via the configured LLM."
  def generate(opts \\ []) do
    ctx = context(opts)
    prompt = render_prompt(ctx)

    LLM.complete(prompt, system: @system_prompt, max_tokens: 800)
  end

  @doc "Generate + post via Telegram."
  def send_now(opts \\ []) do
    case generate(opts) do
      {:ok, text} ->
        post_to_telegram(text)
        {:ok, text}

      {:error, reason} = err ->
        Logger.warning("WeeklyDigest generate failed: #{inspect(reason)}")
        err
    end
  end

  defp post_to_telegram(text) do
    case Counterflow.Alerts.Telegram.credentials() do
      {:ok, token, chat_id} ->
        url = (Application.get_env(:counterflow, :telegram_base, "https://api.telegram.org")) <>
                "/bot#{token}/sendMessage"

        body = %{
          "chat_id" => chat_id,
          "text" => "📊 *Counterflow weekly digest*\n\n" <> text,
          "parse_mode" => "Markdown",
          "disable_web_page_preview" => true
        }

        Req.post(url, json: body, finch: Counterflow.Finch, retry: false, receive_timeout: 10_000)

      {:error, reason} ->
        Logger.info("Telegram not configured for digest: #{reason}")
        :ok
    end
  end

  # ── data sources ────────────────────────────────────────────

  defp signal_stats(cutoff) do
    rows =
      Repo.all(
        from s in Signal,
          where: s.generated_at > ^cutoff,
          select: %{side: s.side, outcome: s.outcome, score: s.score}
      )

    total = length(rows)
    longs = Enum.count(rows, &(&1.side == "long"))
    shorts = Enum.count(rows, &(&1.side == "short"))

    outcomes = Enum.map(rows, & &1.outcome)
    tp1 = Enum.count(outcomes, &match?(%{"hit_tp1" => true}, &1))
    tp2 = Enum.count(outcomes, &match?(%{"hit_tp2" => true}, &1))
    sl = Enum.count(outcomes, &match?(%{"hit_sl" => true}, &1))
    expired = Enum.count(outcomes, fn o -> is_nil(o) || o == %{} end)

    avg_score =
      rows
      |> Enum.map(&dec_to_float(&1.score))
      |> Enum.reject(&(&1 == 0.0))
      |> avg()

    %{
      total: total,
      longs: longs,
      shorts: shorts,
      tp1_hits: tp1,
      tp2_hits: tp2,
      sl_hits: sl,
      expired: expired,
      win_rate: pct(tp1 + tp2, total - expired),
      avg_score: avg_score
    }
  end

  defp paper_stats(cutoff) do
    fills_count = Repo.aggregate(from(f in PaperFill, where: f.filled_at > ^cutoff), :count)

    closed_pnl =
      Repo.one(
        from p in PaperPosition,
          where: p.closed_at > ^cutoff,
          select: sum(p.realized_pnl)
      ) || Decimal.new(0)

    closed_count = Repo.aggregate(from(p in PaperPosition, where: p.closed_at > ^cutoff), :count)
    open_count = Repo.aggregate(from(p in PaperPosition, where: is_nil(p.closed_at)), :count)

    %{
      fills: fills_count,
      closed_positions: closed_count,
      open_positions: open_count,
      realized_pnl_usd: dec_to_float(closed_pnl)
    }
  end

  defp auto_tune_stats(cutoff) do
    runs =
      Repo.all(
        from r in "auto_tune_runs",
          where: r.ran_at > ^cutoff,
          select: %{
            symbol: r.symbol,
            previous: r.previous_threshold,
            selected: r.selected_threshold
          }
      )

    changes =
      runs
      |> Enum.filter(fn r -> r.selected != nil and r.previous != r.selected end)
      |> Enum.map(fn r ->
        %{
          symbol: r.symbol,
          before: dec_to_float(r.previous),
          after: dec_to_float(r.selected)
        }
      end)
      |> Enum.take(10)

    %{runs: length(runs), threshold_changes: changes}
  end

  defp watchlist_stats(cutoff) do
    promoted =
      Repo.all(
        from w in WatchlistEntry,
          where: w.added_at > ^cutoff and like(w.promoted_by, "auto:%"),
          select: w.symbol
      )

    %{auto_promotions: length(promoted), promoted_symbols: Enum.take(promoted, 10)}
  end

  defp risk_stats(cutoff) do
    killswitch =
      Repo.aggregate(from(k in KillswitchEvent, where: k.engaged_at > ^cutoff), :count)

    rejections =
      Repo.all(
        from r in Rejection,
          where: r.attempted_at > ^cutoff,
          group_by: r.rejected_by,
          select: {r.rejected_by, count(r.id)}
      )
      |> Map.new()

    %{killswitch_events: killswitch, rejections_by_gate: rejections}
  end

  defp top_symbols(cutoff) do
    Repo.all(
      from s in Signal,
        where: s.generated_at > ^cutoff,
        group_by: s.symbol,
        order_by: [desc: count(s.id)],
        limit: 5,
        select: %{symbol: s.symbol, count: count(s.id)}
    )
  end

  # ── prompt rendering ────────────────────────────────────────

  defp render_prompt(ctx) do
    """
    Here is the structured report context for the past #{ctx.window_days} days
    (generated at #{DateTime.to_iso8601(ctx.generated_at)} UTC):

    SIGNALS
    - total: #{ctx.signals.total}  (longs: #{ctx.signals.longs}, shorts: #{ctx.signals.shorts})
    - outcome: TP1 hits #{ctx.signals.tp1_hits}, TP2 hits #{ctx.signals.tp2_hits}, SL hits #{ctx.signals.sl_hits}, expired/pending #{ctx.signals.expired}
    - win rate: #{format_pct(ctx.signals.win_rate)}
    - avg score: #{format_num(ctx.signals.avg_score)}

    PAPER
    - fills: #{ctx.paper.fills}
    - closed positions: #{ctx.paper.closed_positions}  (open: #{ctx.paper.open_positions})
    - realized PnL: $#{format_num(ctx.paper.realized_pnl_usd)}

    AUTO-TUNE
    - runs: #{ctx.auto_tune.runs}
    - threshold changes (up to 10): #{format_changes(ctx.auto_tune.threshold_changes)}

    WATCHLIST
    - auto-promotions: #{ctx.watchlist.auto_promotions}
    - example symbols: #{Enum.join(ctx.watchlist.promoted_symbols, ", ")}

    RISK
    - kill-switch events: #{ctx.risk.killswitch_events}
    - rejection counts by gate: #{inspect(ctx.risk.rejections_by_gate)}

    TOP SIGNAL-EMITTING SYMBOLS
    #{Enum.map_join(ctx.top_symbols, "\n", fn s -> "- #{s.symbol}: #{s.count}" end)}

    Write the digest now.
    """
  end

  # ── small helpers ───────────────────────────────────────────

  defp pct(_, 0), do: 0.0
  defp pct(num, denom) when is_number(num) and is_number(denom), do: num / denom
  defp pct(_, _), do: 0.0

  defp format_pct(n) when is_number(n), do: "#{Float.round(n * 100, 1)}%"
  defp format_pct(_), do: "—"

  defp format_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_num(n) when is_integer(n), do: Integer.to_string(n)
  defp format_num(_), do: "—"

  defp format_changes([]), do: "(none)"

  defp format_changes(list) do
    list
    |> Enum.map_join(", ", fn c -> "#{c.symbol}: #{c.before}→#{c.after}" end)
  end

  defp avg([]), do: 0.0
  defp avg(list) when is_list(list), do: Enum.sum(list) / length(list)

  defp dec_to_float(nil), do: 0.0
  defp dec_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp dec_to_float(n) when is_number(n), do: n / 1
  defp dec_to_float(_), do: 0.0
end
