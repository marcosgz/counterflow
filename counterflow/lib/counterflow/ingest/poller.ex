defmodule Counterflow.Ingest.Poller do
  @moduledoc """
  Generic periodic REST poller. Subclasses implement `poll/1` and `persist/2`.

  The poller schedules itself with `Process.send_after/3`, runs the work in
  a try/rescue so a single bad fetch does not crash the worker, and emits
  telemetry events so callers can observe success/failure rates.
  """

  defmacro __using__(opts) do
    quote do
      use GenServer
      require Logger

      @interval_ms unquote(Keyword.fetch!(opts, :interval_ms))
      @poller_name unquote(Keyword.fetch!(opts, :name))

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(opts) do
        {:ok, opts, {:continue, :first_tick}}
      end

      @impl true
      def handle_continue(:first_tick, state) do
        send(self(), :tick)
        {:noreply, state}
      end

      @impl true
      def handle_info(:tick, state) do
        start = System.monotonic_time(:millisecond)

        try do
          poll(state)

          :telemetry.execute(
            [:counterflow, :poll, :ok],
            %{duration_ms: System.monotonic_time(:millisecond) - start},
            %{poller: @poller_name}
          )
        rescue
          err ->
            Logger.warning("[#{@poller_name}] poll failed: #{Exception.message(err)}")

            :telemetry.execute([:counterflow, :poll, :error], %{count: 1}, %{
              poller: @poller_name,
              kind: err.__struct__
            })
        end

        Process.send_after(self(), :tick, @interval_ms)
        {:noreply, state}
      end
    end
  end
end
