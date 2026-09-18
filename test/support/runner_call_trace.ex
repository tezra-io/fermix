defmodule FermixTestSupport.RunnerCallTrace do
  @moduledoc """
  Records the arguments a test's own process hands to
  `FermixCore.CommandRunner.run/3`, so a test can prove what a spawn was given
  (its argv, its environment) without spawning anything itself.

  Only the calling test process is traced, so a concurrent test's commands
  produce nothing here. A process's call trace is never delivered to that
  process, so a linked forwarder is the tracer and relays each event back; it
  dies with the test, and the trace pattern is cleared on exit.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias FermixCore.CommandRunner

  @mfa {CommandRunner, :run, 3}
  @await_ms 2_000

  @doc "Start recording this test process's `CommandRunner.run/3` calls."
  @spec start() :: :ok
  def start do
    test_pid = self()
    tracer = spawn_link(fn -> forward(test_pid) end)

    Code.ensure_loaded!(CommandRunner)
    1 = :erlang.trace(test_pid, true, [:call, {:tracer, tracer}])
    1 = :erlang.trace_pattern(@mfa, true, [:global])
    ExUnit.Callbacks.on_exit(fn -> :erlang.trace_pattern(@mfa, false, [:global]) end)
    :ok
  end

  @doc """
  The recorded call whose argv carries `marker`, skipping every other call (a
  credential helper's lookup runs through the runner too). Bounded by the calls
  already made plus one timeout.
  """
  @spec call_with(String.t()) :: {String.t(), [String.t()], keyword()}
  def call_with(marker) when is_binary(marker) do
    receive do
      {:trace, _pid, :call, {CommandRunner, :run, [executable, args, opts]}} ->
        if marker in args, do: {executable, args, opts}, else: call_with(marker)
    after
      @await_ms -> flunk("no CommandRunner.run/3 call carried #{inspect(marker)}")
    end
  end

  defp forward(test_pid) do
    receive do
      message ->
        send(test_pid, message)
        forward(test_pid)
    end
  end
end
