defmodule FermixCore.PhoneCalls.Tools do
  @moduledoc """
  The phone-call feature's built-in tools (M94 §06, §07), and where each one
  lives.

    * `registered/0`: what the owner's capability registry holds,
      `phone_call` alone, seeded on every boot whether phone calls are on or
      off (`Capabilities.BuiltinSeeder`), its `advertise?/1` deciding whom it
      is offered to.
    * `controls/0`: the in-call controls, keypad then end call. No registry
      holds them: a call's own backend turn builds them for itself
      (`Agents.PhoneCallTurn`), and no brief can grant them
      (`PhoneCalls.Grants`).
    * `modules/0`: the whole family, every module the classification guard
      covers.
  """

  alias FermixCore.Tools.PhoneCall
  alias FermixCore.Tools.PhoneCallEnd
  alias FermixCore.Tools.PhoneCallPressKeys

  @registered [PhoneCall]
  @controls [PhoneCallPressKeys, PhoneCallEnd]

  @doc "What the owner's capability registry holds: `phone_call`."
  @spec registered() :: [module(), ...]
  def registered, do: @registered

  @doc "The in-call controls every backend turn of a call has: keypad, then end call."
  @spec controls() :: [module(), ...]
  def controls, do: @controls

  @doc "The controls' names, in `controls/0` order."
  @spec control_names() :: [String.t(), ...]
  def control_names, do: Enum.map(@controls, & &1.name())

  @doc "The whole family: `phone_call`, then the in-call controls."
  @spec modules() :: [module(), ...]
  def modules, do: @registered ++ @controls
end
