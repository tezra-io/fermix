defmodule FermixChannels.Gateway.Typing do
  @moduledoc """
  Typing indicator for a gateway turn.

  `with_indicator/3` runs `fun` while periodically invoking `typing_fn` (a
  0-arity channel closure, e.g. Telegram's `sendChatAction`) on a `spawn_link`ed
  loop, stopping when `fun` returns. The loop is linked to the calling turn task
  so an unexpected typing exception crashes the turn rather than being swallowed;
  individual transport failures are logged and tolerated.

  Relocated from core in Stage 6 — the gateway owns all channel I/O, so core
  turn execution no longer takes a `typing_fn`.
  """

  require Logger

  @default_interval_ms 4_000
  @default_timeout_ms 300_000

  @spec with_indicator((-> any()) | nil, keyword(), (-> result)) :: result when result: var
  def with_indicator(typing_fn, opts, fun)
      when is_function(typing_fn, 0) and is_function(fun, 0) do
    pid =
      spawn_link(fn ->
        typing_loop(
          typing_fn,
          positive_integer(Keyword.get(opts, :interval_ms), @default_interval_ms),
          monotonic_ms() + positive_integer(Keyword.get(opts, :timeout_ms), @default_timeout_ms)
        )
      end)

    try do
      fun.()
    after
      stop_typing_loop(pid)
    end
  end

  def with_indicator(_typing_fn, _opts, fun) when is_function(fun, 0), do: fun.()

  defp typing_loop(typing_fn, interval_ms, deadline_ms) do
    case emit_typing(typing_fn) do
      :ok ->
        wait_for_next_typing_tick(typing_fn, interval_ms, deadline_ms)

      {:error, _reason} ->
        :ok
    end
  end

  defp wait_for_next_typing_tick(typing_fn, interval_ms, deadline_ms) do
    now = monotonic_ms()

    if now >= deadline_ms do
      :ok
    else
      receive do
        :stop -> :ok
      after
        min(interval_ms, deadline_ms - now) ->
          typing_loop(typing_fn, interval_ms, deadline_ms)
      end
    end
  end

  defp emit_typing(typing_fn) do
    case typing_fn.() do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Typing indicator failed: #{inspect(reason)}")
        error

      other ->
        Logger.warning("Typing indicator returned unexpected result: #{inspect(other)}")
        {:error, other}
    end
  rescue
    error in [Req.TransportError] ->
      Logger.warning("Typing indicator transport failed: #{Exception.message(error)}")
      {:error, error}
  catch
    :exit, {:noproc, _details} = reason ->
      Logger.warning("Typing indicator adapter unavailable: #{inspect(reason)}")
      {:error, reason}

    :exit, :noproc ->
      Logger.warning("Typing indicator adapter unavailable: :noproc")
      {:error, :noproc}
  end

  defp stop_typing_loop(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      100 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          100 -> :ok
        end
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
