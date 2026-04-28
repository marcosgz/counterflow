defmodule Counterflow.Alerts.Telegram do
  @moduledoc """
  Telegram bot sink for the alert dispatcher. Posts each emitted signal to
  a configured chat via the Bot API.

  Configuration (via env or app config):
    * TELEGRAM_BOT_TOKEN — required (e.g. "123456789:AA-...")
    * TELEGRAM_CHAT_ID   — required (numeric chat id, can be negative for groups)

  Activate by including this module in :counterflow, :alert_sinks:

      config :counterflow, :alert_sinks, [Counterflow.Alerts.Telegram]

  Or set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID and rely on the
  dispatcher's runtime sink list.
  """

  require Logger

  alias Counterflow.Strategy.Signal

  @spec send(Signal.t()) :: {:ok, map()} | {:error, term()}
  def send(%Signal{} = sig) do
    case credentials() do
      {:ok, token, chat_id} ->
        post(token, chat_id, format(sig))

      {:error, reason} ->
        Logger.debug("Telegram sink skipped: #{reason}")
        {:error, reason}
    end
  end

  @spec test_message(String.t()) :: {:ok, map()} | {:error, term()}
  def test_message(text \\ "Counterflow Telegram sink: connection test ✓") do
    with {:ok, token, chat_id} <- credentials() do
      post(token, chat_id, text)
    end
  end

  @spec configured?() :: boolean()
  def configured? do
    case credentials() do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  @doc false
  def credentials do
    cfg = Application.get_env(:counterflow, __MODULE__, [])
    token = cfg[:bot_token] || System.get_env("TELEGRAM_BOT_TOKEN")
    chat_id = cfg[:chat_id] || System.get_env("TELEGRAM_CHAT_ID")

    cond do
      is_nil(token) or token == "" -> {:error, :missing_token}
      is_nil(chat_id) or chat_id == "" -> {:error, :missing_chat_id}
      true -> {:ok, token, chat_id}
    end
  end

  defp post(token, chat_id, text) do
    base = Application.get_env(:counterflow, :telegram_base, "https://api.telegram.org")
    url = "#{base}/bot#{token}/sendMessage"

    body = %{
      "chat_id" => chat_id,
      "text" => text,
      "parse_mode" => "Markdown",
      "disable_web_page_preview" => true
    }

    case Req.post(url, json: body, finch: Counterflow.Finch, retry: false, receive_timeout: 8_000) do
      {:ok, %{status: 200, body: %{"ok" => true} = resp}} ->
        {:ok, resp}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Telegram sink non-200 #{status}: #{inspect(body)}")
        {:error, {status, body}}

      {:error, exc} ->
        Logger.warning("Telegram sink transport error: #{Exception.message(exc)}")
        {:error, exc}
    end
  end

  defp format(%Signal{} = sig) do
    side_emoji = if sig.side == "long", do: "🟢", else: "🔴"
    score = format_decimal(sig.score)
    price = format_decimal(sig.price)
    sl = format_decimal(sig.sl)
    tp1 = format_decimal(sig.tp1)
    tp2 = format_decimal(sig.tp2)

    """
    #{side_emoji} *#{escape(String.upcase(sig.side))}* `#{escape(sig.symbol)}` _(#{escape(sig.interval)})_

    *Entry*  `#{price}`
    *Score*  `#{score}`  _·_  *Lev*  `#{sig.leverage}×`
    *SL*  `#{sl}`  ·  *TP1*  `#{tp1}`  ·  *TP2*  `#{tp2}`

    _#{escape(notes_line(sig))}_
    """
  end

  defp notes_line(%Signal{notes: notes}) when is_list(notes) and notes != [],
    do: Enum.join(notes, " · ")

  defp notes_line(_), do: "no notable components"

  defp format_decimal(nil), do: "—"
  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_decimal(other), do: to_string(other)

  # Telegram Markdown is finicky; escape the few characters we care about.
  defp escape(nil), do: ""

  defp escape(str) when is_binary(str) do
    str
    |> String.replace("_", "\\_")
    |> String.replace("*", "\\*")
    |> String.replace("`", "\\`")
    |> String.replace("[", "\\[")
  end

  defp escape(other), do: to_string(other)
end
