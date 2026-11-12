defmodule FermixCore.Computers.Choice do
  @moduledoc """
  Where a tool call runs (M97 §6.5): on this server or on one of the home's
  computers, for a tool a computer can run (`metadata.computer`, its
  `computer_capability/0`). The rules are fixed and never silent:

    * no `computer`, in a turn whose earlier calls of the capability ran
      on a computer (its `continues_on/1`, the browser's): that computer,
      refused as a named one is when it is away, and by itself when it is no
      longer the home's; a task never moves back here silently;
    * no `computer`, and this engine's host has the capability (its
      `here?/1`): here;
    * no `computer`, and exactly one computer offers it: that one;
    * no `computer`, and several do: refused, asking for a name
      (`ambiguous`); and none does: refused (`not_offered`);
    * a computer named that is away: refused at once, with when it was last
      seen (`away`); nothing waits for it to wake;
    * a name no computer of the home has (`no_such_computer`), a computer
      past the version window (`settings_only`) and one that does not offer
      the capability (`not_offered`): refused by name.

  `resolve/3` answers the call's arguments without `computer` and the context
  with `:computer`, `:here` or the `Computer` the call runs on, which
  `Capabilities.AccessGate` decides with and the tool reads. A tool with no
  computer capability is passed through untouched: its arguments are its own.

  A refusal runs nothing and sends nothing: `refuse/5` emits the call's one
  `[:fermix, :tool, :exec]` event, with `computer_refusal` and the typed
  pre-execution marker (the pattern `AccessGate.held_metadata/2` sets), and is
  the tool result the model reads. These refusals are the home's own, so they
  are not in `Computers.Outcome`'s wire set.

  The home's computers are the ones the turn can see
  (`Argument.computers/1`, by `Computers.visible?/1`), read only when a call
  names a computer or the host lacks the capability: a turn that cannot see
  them (a guest's, or a skill's or sub-agent's worker, `Computers.turn_trust/1`,
  which is never offered the argument but can still send it) names no
  computer of the home, and the link is not asked.
  """

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Clock
  alias FermixCore.Computers.Argument
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Offers
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @typedoc "Why the home refused a call before sending anything."
  @type refusal :: :away | :ambiguous | :no_such_computer | :not_offered | :settings_only

  @refusals [:away, :ambiguous, :no_such_computer, :not_offered, :settings_only]

  @doc "Every refusal, in the order the moduledoc lists them."
  @spec refusals() :: [refusal()]
  def refusals, do: @refusals

  @doc "Where the call runs (the moduledoc)."
  @spec resolve(Capability.t(), map(), map()) ::
          {:ok, map(), map()} | {:refused, refusal(), String.t()}
  def resolve(%Capability{metadata: %{computer: module}}, args, context)
      when is_atom(module) and is_map(args) and is_map(context) do
    {name, run_args} = Map.pop(args, Argument.property())

    with {:ok, target} <- target(name, module, context),
         do: {:ok, run_args, Map.put(context, :computer, target)}
  end

  def resolve(%Capability{}, args, context) when is_map(args) and is_map(context),
    do: {:ok, args, context}

  @doc """
  The refused call's tool result, after its one exec event: the executor
  never ran and nothing reached a computer.
  """
  @spec refuse(Capability.t(), map(), map(), refusal(), String.t()) :: Tool.tool_result()
  def refuse(%Capability{name: name}, args, context, refusal, sentence)
      when refusal in @refusals and is_map(args) and is_map(context) and is_binary(sentence) do
    ToolTelemetry.exec(name, context, false, 0, metadata: refusal_metadata(refusal), input: args)
    Tool.error(sentence)
  end

  @doc """
  What a refused call's exec event carries: the refusal, a typed proof that
  nothing ran, and a bounded error. Closed words only, never a name.
  """
  @spec refusal_metadata(refusal()) :: map()
  def refusal_metadata(refusal) when refusal in @refusals do
    %{
      computer_refusal: Atom.to_string(refusal),
      policy_enforcement: %{source: "computers", decision: "deny", phase: "pre_execution"},
      error_code: "computer_#{refusal}",
      error_summary: "refused before anything was sent to a computer"
    }
  end

  # -- the rules ---------------------------------------------------------------

  defp target(nil, module, context), do: carried_on(module, context)
  defp target("", module, context), do: carried_on(module, context)

  defp target(name, module, context) when is_binary(name) do
    wanted = String.downcase(name)

    case Enum.find(computers(context), &(String.downcase(&1.name) == wanted)) do
      nil -> {:refused, :no_such_computer, no_such_sentence(name)}
      computer -> usable(computer, module)
    end
  end

  defp target(_not_a_name, _module, _context),
    do: {:refused, :no_such_computer, "Name the computer as ## Computers lists it."}

  # A turn whose earlier calls ran on a computer carries on there
  # (`continues_on/1`), refused as any named call is when it cannot.
  defp carried_on(module, context) do
    case continues_on(module, context) do
      nil -> unnamed(module, context)
      device_id -> carried_on(module, context, device_id)
    end
  end

  defp carried_on(module, context, device_id) do
    case Enum.find(computers(context), &(&1.device_id == device_id)) do
      nil -> {:refused, :no_such_computer, gone_sentence()}
      computer -> usable(computer, module)
    end
  end

  defp continues_on(module, context) do
    if Code.ensure_loaded?(module) and function_exported?(module, :continues_on, 1),
      do: module.continues_on(context),
      else: nil
  end

  defp unnamed(module, context) do
    if here?(module, context),
      do: {:ok, :here},
      else: only_one(module, Argument.offering(computers(context), module))
  end

  defp only_one(module, [computer]), do: usable(computer, module)
  defp only_one(module, []), do: {:refused, :not_offered, nobody_sentence(module)}

  defp only_one(module, several),
    do: {:refused, :ambiguous, ambiguous_sentence(module, Enum.map(several, & &1.name))}

  # Away first: what an away computer offers is only what it last said.
  defp usable(%Computer{connected: false} = computer, _module),
    do: {:refused, :away, away_sentence(computer)}

  defp usable(%Computer{standing: :settings_only, name: name}, _module),
    do: {:refused, :settings_only, settings_only_sentence(name)}

  defp usable(%Computer{} = computer, module) do
    if Argument.offers?(computer, module),
      do: {:ok, computer},
      else: {:refused, :not_offered, not_offered_sentence(computer, module)}
  end

  defp here?(module, context) do
    Code.ensure_loaded?(module) and function_exported?(module, :here?, 1) and
      module.here?(context)
  end

  # The computers this turn can see (`Argument.computers/1`, the rule of
  # `Computers.visible?/1`): a turn that cannot see them names none.
  defp computers(context), do: Argument.computers(context)

  # -- what the model is told -------------------------------------------------------

  defp away_sentence(%Computer{name: name, last_seen: %DateTime{} = at}),
    do:
      "#{name} is asleep or offline (last seen #{Clock.stated_instant(at)}), so Fermix " <>
        "cannot reach it now. Nothing waits for it to wake."

  defp away_sentence(%Computer{name: name}),
    do: "#{name} has not connected yet, so Fermix cannot reach it now."

  defp settings_only_sentence(name),
    do:
      "#{name} runs a Fermix too old for this server, so it is used for settings only " <>
        "until it updates."

  defp no_such_sentence(name), do: "Your Fermix has no computer called #{name}."

  defp gone_sentence,
    do:
      "The computer this task ran on is no longer one of yours, so it does not carry on " <>
        "anywhere else. Tell the owner."

  defp nobody_sentence(module), do: "None of your computers offers #{label(module)} now."

  defp ambiguous_sentence(module, [_first, _second] = names),
    do: "#{joined(names)} both offer #{label(module)}. Name the computer to use."

  defp ambiguous_sentence(module, names),
    do: "#{joined(names)} all offer #{label(module)}. Name the computer to use."

  defp not_offered_sentence(%Computer{name: name, offers: []}, _module),
    do: "#{name} has not said yet what Fermix may use there."

  defp not_offered_sentence(%Computer{name: name, offers: offers}, module) do
    wanted = module.offer() && Atom.to_string(module.offer())

    case Enum.find(offers, &(&1.id == wanted)) do
      %{state: :off} ->
        "#{name} has #{label(module)} switched off. Only someone at #{name} can switch it on."

      %{state: :unavailable, sentence: sentence} when is_binary(sentence) ->
        "#{name} does not offer #{label(module)} now. It says: #{sentence}"

      _absent ->
        "#{name} does not offer #{label(module)}."
    end
  end

  defp joined([first, second]), do: "#{first} and #{second}"
  defp joined(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  # The words an offer goes by ("files", "commands"), from its offer module.
  defp label(module) do
    wanted = module.offer()

    Enum.find_value(Offers.modules(), Atom.to_string(module.id()), fn offer ->
      if offer.id() == wanted, do: offer.label()
    end)
  end

  @doc "Every sentence a refusal says, for the copy rules, on a computer called studio Mac."
  @spec sentences(module()) :: [String.t()]
  def sentences(module) when is_atom(module) do
    seen = ~U[2026-11-08 22:14:00Z]
    base = %Computer{device_id: "device-1", name: "studio Mac", connected: true}
    offer = module.offer() && Atom.to_string(module.offer())

    [
      away_sentence(%{base | connected: false, last_seen: seen}),
      away_sentence(%{base | connected: false}),
      settings_only_sentence("studio Mac"),
      no_such_sentence("studio Mac"),
      gone_sentence(),
      nobody_sentence(module),
      ambiguous_sentence(module, ["studio Mac", "loft Linux"]),
      ambiguous_sentence(module, ["studio Mac", "loft Linux", "attic Mac"]),
      not_offered_sentence(base, module),
      not_offered_sentence(%{base | offers: [%{id: offer, state: :off}]}, module),
      not_offered_sentence(
        %{base | offers: [%{id: offer, state: :unavailable, sentence: "Not on this Mac."}]},
        module
      ),
      not_offered_sentence(%{base | offers: [%{id: "browser", state: :on}]}, module)
    ]
  end
end
