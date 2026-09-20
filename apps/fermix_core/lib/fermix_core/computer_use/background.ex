defmodule FermixCore.ComputerUse.Background do
  @moduledoc """
  Everything the experimental bound-window surface adds, in one list (M42 slice 5
  §1, §4).

  The surface is one window the model binds and then works inside: it sees that
  window even when another covers it, presses its controls by name without taking
  the pointer, and the helper shows on screen that it is doing so. None of it can
  be proved without a real screen and a person watching, so all of it sits behind
  `[fermix_core.computer_use] background`, off by default, until the owner's live
  check qualifies it.

  **Why the list is here and not spread across its consumers.** A flag that gates
  four surfaces — the action enum, the request fields, the tool's own words and
  the runtime steering — is gated four times, and the fourth is the one somebody
  forgets. Every consumer reads these lists, and the whole-surface test loops over
  the same ones, so a token or a sentence added later either joins the invariant
  or fails it. Nothing here is a copy of anything: `Compux.Protocol` owns which
  actions EXIST, and this module owns which of them this flag REVEALS.

  Two gates, not one, and they answer different questions. The flag says whether
  the operator wants the surface; `available?/1` says whether the installed helper
  can carry it, read from the `hello` capabilities it published at the handshake.
  A helper with no `targets` capability, or one whose on-screen indicator is
  missing, cannot honour a bound target, so the surface does not run against it —
  and `fermix doctor` is where an operator reads why.
  """

  alias FermixCore.ComputerUse.Config

  # The model-facing actions the flag reveals. They are in `Compux.Protocol` at
  # every build; what the flag decides is whether the tool's schema offers them.
  @actions ~w(select_target release_target)

  # The schema properties the flag reveals, beside those actions.
  @parameters ~w(window_id)

  # The request fields Fermix adds on the wire while a window target is held. The
  # model never sends one — the session stamps it — so it appears in no schema,
  # and the gate below is what keeps it that way.
  @wire_fields ~w(target_id)

  # The words this surface puts in front of the model: the tool description's
  # paragraph, the runtime steering's sentence, and the sentences the session
  # answers a target refusal with. The gate asserts none of them is rendered while
  # the flag is off, so a new sentence about targets joins the invariant by using
  # the vocabulary it is written in.
  @marker_phrases ["select_target", "release_target", "window_id", "target_id", "bound window"]

  # The `window_id` that means the whole desktop rather than one window: today's
  # foreground mode, chosen explicitly (M42 slice 5 §4). It is not a target on the
  # wire — the helper has no desktop target, it has the ABSENCE of one — so this
  # value never leaves Fermix.
  @desktop_window_id "desktop"

  # The helper codes that exist only inside a bound window. Their sentences
  # explain the capability, so they are as much a part of the surface as the
  # actions are: with the flag off nothing can produce one, and a sentence that
  # taught the model about window binding through the ERROR path would be the
  # surface leaking out the back.
  @codes ~w(target_unavailable target_minimized target_obstructed ax_binding_unavailable
            control_surface_unavailable capture_unavailable capture_budget_exceeded
            screen_recording_not_granted)

  @doc "The helper codes whose sentences belong to this surface."
  @spec codes() :: [String.t()]
  def codes, do: @codes

  @doc "The actions the flag adds to the tool's action enum."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "The schema properties the flag adds beside those actions."
  @spec parameters() :: [String.t()]
  def parameters, do: @parameters

  @doc "The request fields the session stamps while a window target is held."
  @spec wire_fields() :: [String.t()]
  def wire_fields, do: @wire_fields

  @doc """
  Every token this flag can put on the wire or in a schema: the actions, the
  parameters and the wire fields. What the whole-surface gate loops over.
  """
  @spec tokens() :: [String.t()]
  def tokens, do: @actions ++ @parameters ++ @wire_fields

  @doc "The phrases this surface puts in front of the model."
  @spec marker_phrases() :: [String.t()]
  def marker_phrases, do: @marker_phrases

  @doc "The `window_id` that names the whole desktop instead of one window."
  @spec desktop_window_id() :: String.t()
  def desktop_window_id, do: @desktop_window_id

  @doc "Whether this `select_target` asked for the whole desktop."
  @spec desktop?(term()) :: boolean()
  def desktop?(window_id), do: window_id == @desktop_window_id

  @doc "Whether the operator has switched the surface on."
  @spec enabled?(Config.t()) :: boolean()
  def enabled?(%Config{background?: background?}), do: background?

  @doc """
  Whether the installed helper can carry a bound target, from the capabilities it
  published at the handshake (`FermixCore.ComputerUse.Capabilities`).

  Both halves are required and neither is inferred: a build with no `targets`
  capability cannot bind a window at all, and one whose indicator is missing
  could bind a window with nothing on screen to say so — which is the one thing
  background work may not do. An absent reading is not a yes.
  """
  @spec available?(map()) :: boolean()
  def available?(capabilities) when is_map(capabilities) do
    capabilities.targets? and capabilities.indicator == :present
  end

  @doc """
  Why the helper cannot carry a bound target, for the operator sentence that has
  to name it. `nil` when it can.
  """
  @spec unavailable_reason(map()) :: :no_targets | :indicator_missing | :indicator_unknown | nil
  def unavailable_reason(capabilities) when is_map(capabilities) do
    cond do
      not capabilities.targets? -> :no_targets
      capabilities.indicator == :missing -> :indicator_missing
      capabilities.indicator == :unknown -> :indicator_unknown
      true -> nil
    end
  end
end
