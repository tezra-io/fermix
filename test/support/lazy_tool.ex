defmodule FermixTestSupport.LazyTool do
  @moduledoc """
  A tool-shaped executor double whose compiled module lives on disk (it is part
  of the umbrella's shared `test/support`), so a test can UNLOAD it and
  reproduce the running daemon's lazily-loaded world: the module is loadable but
  not loaded, which is exactly the state in which `function_exported?/3` answers
  false and an unchecked advertisement gate offers a tool whose own `advertise?/1`
  would have denied it (MILESTONE_32, the 2026-09-10 `recall_activity` incident).

  Nothing else in the suite uses it, so unloading it disturbs no other test.
  """

  @doc "Denies unless the context explicitly allows it, so `%{}` is a refusal."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context),
    do: Map.get(context, :lazy_tool_allowed?, false)

  @doc "A schema distinguishable from the registered one, to prove the refresh ran."
  @spec dynamic_parameters(map()) :: map()
  def dynamic_parameters(context) when is_map(context),
    do: %{type: "object", properties: %{"refreshed" => %{type: "string"}}}

  @spec execute(map(), map()) :: {:ok, map()}
  def execute(_args, _context), do: {:ok, %{success: true, output: "unused"}}
end

defmodule FermixTestSupport.LazyTool.Unloader do
  @moduledoc """
  Unloads `FermixTestSupport.LazyTool` and puts it back. The final purge runs
  from HERE, never from inside the module being purged: `:code.purge/1` kills
  every process with that module's old code on its stack, and the caller would
  be one of them.
  """

  @module FermixTestSupport.LazyTool

  @doc "Leave the module on disk but absent from the code table."
  @spec unload!() :: :ok
  def unload! do
    {:module, @module} = Code.ensure_loaded(@module)
    :code.purge(@module)
    true = :code.delete(@module)
    :code.purge(@module)
    :ok
  end

  @doc "Load it again (a no-op when it is already loaded)."
  @spec reload!() :: :ok
  def reload! do
    {:module, @module} = Code.ensure_loaded(@module)
    :ok
  end

  @doc "The module this pair loads and unloads."
  @spec module() :: module()
  def module, do: @module
end
