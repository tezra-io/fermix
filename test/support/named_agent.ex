defmodule FermixTestSupport.NamedAgent do
  @moduledoc """
  A named Agent that is the calling test's own.

  A test double often keeps its script or its record in an Agent that other
  processes reach by name. Started with `Agent.start_link/2`, that Agent is
  linked to the test that started it and dies with it, some time after: its
  name stays registered until its scheduler next runs it. So the next test can
  still find it by name, on its way out, or fail to start its own under that
  name (docs/lessons.md, "Tests under load"). Started here it is a child of the
  test's supervisor, which ExUnit stops, and waits for, before the next test
  starts, and after every child the test started later.

  One name serves a module: its tests run one at a time. A name two modules
  share needs both of them `async: false`.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, stop_supervised: 1]

  @doc """
  Starts `name` holding what `fun` returns, in place of the one this test
  already started under that name, if any. Call it from the test process.
  """
  @spec start!(atom(), (-> term())) :: pid()
  def start!(name, fun) when is_atom(name) and is_function(fun, 0) do
    # `{:error, :not_found}` when this test has started none.
    _stopped = stop_supervised(name)
    start_supervised!(%{id: name, start: {Agent, :start_link, [fun, [name: name]]}})
  end
end
