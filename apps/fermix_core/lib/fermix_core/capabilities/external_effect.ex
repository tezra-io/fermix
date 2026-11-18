defmodule FermixCore.Capabilities.ExternalEffect do
  @moduledoc """
  The behaviour of a built-in tool whose call makes an effect outside the
  machine (`phone_call`'s `start` places a call), so that
  `Capabilities.AccessGate` decides it as kind `:external_effect`.

  The kind follows from the module and nowhere else: a capability built from
  a tool module that implements this behaviour
  (`Capabilities.Builtin.from_tool_module/1`) carries
  `metadata.external_effect?`, and no table or manifest sets it, so the two
  cannot disagree. The gate asks the module for everything specific to the
  effect, and a second effect needs no change to the gate:

    * `c:effect/0`, a verb phrase its sentences name the effect by
      ("places a phone call");
    * `c:effect_name/0`, a noun phrase for one such effect while it waits for
      the owner ("a phone call");
    * `c:effect_call?/1`, which of the tool's calls make it, so only those are
      decided;
    * `c:confirmation/2`, what the owner reads before it goes ahead (the
      question, then the rows that change what it does), or the sentence the
      call is refused with when it would certainly be refused anyway, so the
      owner is never asked about it;
    * `c:confirmed/1`, what the owner reads once a call they confirmed has
      run, read from the facts the tool's result carries (`effect`), never by
      parsing its output;
    * `c:context_keys/0`, what else of the turn's context the confirmed call
      runs with (its stores and seams), which the gate keeps in the parked
      call's snapshot beside its own keys.

  The gate composes the rest itself: the reason it asks, the approval line,
  the window, and the refusal when the whole confirmation is too long to show
  in one message. It also owns how a row is shown, so one rule decides it for
  every effect: a list of one on its label's line, a longer list numbered,
  and an empty list no row at all (never "none").

  """

  alias FermixCore.Capabilities.Builtin.Tool

  @typedoc """
  What the owner reads before the effect goes ahead: `head`, the effect as
  the one question the owner answers, which opens the confirmation (the gate
  adds no tool name to it), its values quoted as data; `lines`, each a label
  and its value, or a label and a list of values, every value data the gate
  keeps on its own line, a part that may be absent given as a list so an
  empty one is no row; `promise`, what happens on the owner's yes. A module
  leaves out only what is the same on every call; nothing with content is
  summarized away.
  """
  @type confirmation :: %{
          head: String.t(),
          lines: [{String.t(), String.t() | [String.t()]}],
          promise: String.t()
        }

  @callback effect() :: String.t()
  @callback effect_name() :: String.t()
  @callback effect_call?(args :: map()) :: boolean()
  @callback confirmation(args :: map(), Tool.context()) ::
              {:ok, confirmation()} | {:error, String.t()}

  @doc """
  What the owner reads once a call they confirmed has run: `{:ok, line}` for
  one that made its effect (its result's `effect` facts), `{:error,
  sentence}` for one refused after the confirmation (its result's own error).
  """
  @callback confirmed(Tool.tool_result()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  The context keys a confirmed call reads beyond the gate's own snapshot (the
  session, the request identity, the conversation, the origin): the tool's
  stores and its test seams, frozen at park time.
  """
  @callback context_keys() :: [atom()]

  @doc "Whether `module` implements this behaviour."
  @spec implemented_by?(module()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and __MODULE__ in behaviours(module)
  end

  defp behaviours(module),
    do: module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
end
