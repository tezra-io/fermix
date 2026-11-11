defmodule FermixCore.Computers.Argument do
  @moduledoc """
  The `computer` argument of a tool call (M97 §6.5): which of the home's
  computers runs it, by the name `## Computers` lists.

  A tool that a computer can run names its capability
  (`Builtin.Tool.computer_capability/0`, carried as `metadata.computer`).
  On the server, on an owner's turn, where Always On is offered and the home
  has a computer (`computers/1`), each such tool gains an optional
  `computer` property whose values are the names of the computers that offer
  that capability, an away one included, so the model can name it and hear
  that it is away (`add/2`). A tool no computer offers, a turn with no
  computers, a guest's turn and a build without Always On are left as they
  are. `Capabilities.Advertisement.prepare/2` adds it after a tool's own
  schema refresh, so no tool's refresh drops it; `Computers.Choice` decides
  where each call runs.

  Whether a turn sees the computers at all is `Computers.visible?/1`, the
  rule `## Computers` follows, decided before the link is asked. `computers/1`
  reads the context's `:computers`, `:always_on` and `:computers_opts` (a
  keyword for `Computers`: its `:role` and `:link`) where a test hands them
  in, else `FermixCore.Computers.list/1` and
  `Home.AlwaysOnRelease.available?/0`. `add/2` is pure.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Computers
  alias FermixCore.Computers.Computer
  alias FermixCore.Home.AlwaysOnRelease

  @property "computer"
  @description "Which of the owner's computers runs this, by its name in ## Computers. " <>
                 "Without it, it runs on this server where the server can, else on the one " <>
                 "computer that offers it. A path belongs to one machine: name the computer " <>
                 "it is on."

  @doc "The argument's name in a call."
  @spec property() :: String.t()
  def property, do: @property

  @doc """
  The home's computers for a turn whose loop context is `context`: none
  unless the turn can see them (`Computers.visible?/1`, its trust the
  context's `source_trust`), then the context's `:computers`, else
  `Computers.list/1`'s. The link is asked only after that.
  """
  @spec computers(map()) :: [Computer.t()]
  def computers(context) when is_map(context) do
    opts = computers_opts(context)
    if Computers.visible?(opts), do: listed(context, opts), else: []
  end

  @doc """
  `capability` with the `computer` property when it carries a computer
  capability and one of `computers` offers it; unchanged otherwise.
  """
  @spec add(Capability.t(), [Computer.t()]) :: Capability.t()
  def add(%Capability{metadata: %{computer: module}} = capability, [_ | _] = computers)
      when is_atom(module) do
    case computers |> offering(module) |> Enum.map(& &1.name) do
      [] -> capability
      names -> %{capability | parameters: with_property(capability.parameters, names)}
    end
  end

  def add(%Capability{} = capability, computers) when is_list(computers), do: capability

  @doc """
  The computers that offer `module`'s capability: its offer is on in what
  each last said. One past the version window lists none (`Computers`).
  """
  @spec offering([Computer.t()], module()) :: [Computer.t()]
  def offering(computers, module) when is_list(computers) and is_atom(module),
    do: Enum.filter(computers, &offers?(&1, module))

  @doc "Whether `computer` offers `module`'s capability, by its offer's switch."
  @spec offers?(Computer.t(), module()) :: boolean()
  def offers?(%Computer{offers: offers}, module) when is_atom(module) do
    case module.offer() do
      nil ->
        offers != []

      offer ->
        wanted = Atom.to_string(offer)
        Enum.any?(offers, &(&1.id == wanted and &1.state == :on))
    end
  end

  # The turn's trust, never defaulted: a context without one sees nothing.
  defp computers_opts(context) do
    context
    |> Map.get(:computers_opts, [])
    |> Keyword.put(:trust, Map.get(context, :source_trust))
    |> Keyword.put_new_lazy(:always_on, fn ->
      Map.get_lazy(context, :always_on, &AlwaysOnRelease.available?/0)
    end)
  end

  defp listed(%{computers: computers}, _opts) when is_list(computers), do: computers
  defp listed(_context, opts), do: Computers.list(opts)

  # The property beside the tool's own, in the same key style its schema
  # uses; a schema with no properties gains them.
  defp with_property(%{properties: properties} = schema, names) when is_map(properties),
    do: %{schema | properties: Map.put(properties, :computer, spec(names))}

  defp with_property(%{"properties" => properties} = schema, names) when is_map(properties),
    do: %{schema | "properties" => Map.put(properties, @property, string_spec(names))}

  defp with_property(%{} = schema, names),
    do: Map.put(schema, :properties, %{computer: spec(names)})

  defp spec(names), do: %{type: "string", enum: names, description: @description}

  defp string_spec(names),
    do: %{"type" => "string", "enum" => names, "description" => @description}
end
