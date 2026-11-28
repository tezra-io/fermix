defmodule FermixTestSupport.NamedTest do
  @moduledoc """
  The calling test's own process under a name, for as long as the test runs.

  A fake that is a module (an adapter, a store) reports to its test through a
  name the test registers. `Process.register(self(), name)` in a setup leaves
  the name held until the test's process ends, and ExUnit does not wait for
  that: a test's process tells the runner it has finished and exits after, and
  the runner goes on at the message (`ExUnit.Runner.spawn_test/3`). So the next
  test's setup can find the name still taken, and an `on_exit` that looks the
  name up before it unregisters it can find it gone in between
  (docs/lessons.md, "Tests under load").

  `register!/1` registers the test and waits, in an `on_exit`, for the test's
  process to end. ExUnit runs every `on_exit` of a test, and waits for it,
  before it starts the next test.

  One name serves a module: its tests run one at a time. A name two modules
  share needs both of them `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 2]

  # A test's process exits as soon as it has reported; this bounds a wait for
  # an event that is already on its way.
  @ends_within_ms 10_000

  @doc "Registers the calling test's process as `name` until the test ends."
  @spec register!(atom()) :: true
  def register!(name) when is_atom(name) do
    test = self()
    true = Process.register(test, name)
    on_exit({__MODULE__, test}, fn -> await_end(test) end)
    true
  end

  defp await_end(test) do
    ref = Process.monitor(test)

    receive do
      {:DOWN, ^ref, :process, ^test, _reason} -> :ok
    after
      @ends_within_ms ->
        raise "test process #{inspect(test)} was still alive #{@ends_within_ms} ms after its test"
    end
  end
end
