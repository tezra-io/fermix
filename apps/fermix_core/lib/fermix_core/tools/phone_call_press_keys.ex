defmodule FermixCore.Tools.PhoneCallPressKeys do
  @moduledoc """
  `phone_call_press_keys` (M94 §07, §08): press keypad keys on the phone call
  whose backend turn this is, to choose what an automated menu asks for.

  Built and offered only by a phone call's backend turn
  (`Agents.PhoneCallTurn`), which makes its capability from this module: no
  capability registry holds it, so no other turn can be offered or run it,
  and `execute/2` still refuses outside such a turn
  (`Agents.PhoneCallTurn.in_call/1`). The call is the turn's own, named by
  the context: its id and the handle the call's worker minted for this turn,
  never a model argument, so no call can be reached by naming it. The worker
  checks the handle again and owns every keypad bound (one key in flight, its
  acknowledgement, the call's key cap); what it reports confirmed and what it
  could not confirm come back as they are. Which keys may be sent at all
  (never a card or account number, a password or a code that proves identity)
  is the backend context's rule (`PhoneCalls.Prompt`).

  One `[:fermix, :tool, :exec]` event per model call under this name,
  refusals included. Its metadata carries how many keys were asked for, never
  the keys.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.PhoneCallTurn
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.OpenAILive.Controls
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @name "phone_call_press_keys"

  @impl true
  @spec name() :: String.t()
  def name, do: @name

  @impl true
  @spec description() :: String.t()
  def description do
    "Press keys on this phone call's keypad to choose the option an automated menu asked " <>
      "for. Send only keys the menu asked for: never a card or account number, a password, " <>
      "or a code that proves identity."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["keys"],
      properties: %{
        keys: %{
          type: "string",
          description:
            "The keys to press, in order: digits 0-9, * and #, at most " <>
              "#{Limits.max_dtmf_keys()}."
        }
      }
    }
  end

  @impl true
  @spec when_to_use() :: String.t()
  def when_to_use, do: "When an automated menu on this call asks for a key press."

  @impl true
  @spec failure_modes() :: [map()]
  def failure_modes do
    [
      %{tag: "not_in_call", description: "not a phone call's backend turn"},
      %{tag: "invalid_keys", description: "keys that are not keypad keys, or too many"},
      %{tag: "refused", description: "the call's worker did not press them"}
    ]
  end

  @impl true
  @spec requires_setup() :: nil
  def requires_setup, do: nil

  @impl true
  @spec category() :: atom()
  def category, do: :phone_call

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    started = System.monotonic_time(:millisecond)
    result = run(args, context)
    duration = System.monotonic_time(:millisecond) - started

    ToolTelemetry.exec(@name, context, match?({:ok, %{success: true}}, result), duration,
      metadata: metadata(args, result),
      result: result
    )

    result
  end

  defp run(args, context) do
    with {:ok, call} <- in_call(context),
         {:ok, keys} <- fetch_keys(args),
         {:ok, pressed} <- call.controls.press_keys(call.call_id, call.handle, keys) do
      {:ok, Tool.success(Jason.encode!(pressed_view(pressed)))}
    else
      {:error, reason} -> {:ok, Tool.error(sentence(reason))}
    end
  end

  defp in_call(context) do
    case PhoneCallTurn.in_call(context) do
      {:ok, call} -> {:ok, call}
      :none -> {:error, :not_in_call}
    end
  end

  defp fetch_keys(%{"keys" => keys}) when is_binary(keys) do
    if Controls.dtmf_keys?(keys) and String.length(keys) <= Limits.max_dtmf_keys(),
      do: {:ok, keys},
      else: {:error, :invalid_keys}
  end

  defp fetch_keys(_args), do: {:error, :invalid_keys}

  # What the worker reports, as it reports it: the keys acknowledged, the ones
  # it could not confirm, and why it stopped pressing (`nil` when it did not).
  defp pressed_view(%{confirmed: confirmed, unconfirmed: unconfirmed} = pressed)
       when is_binary(confirmed) and is_binary(unconfirmed) do
    %{
      confirmed: confirmed,
      unconfirmed: unconfirmed,
      stopped: stopped_word(Map.get(pressed, :stopped)),
      detail: detail(unconfirmed)
    }
  end

  defp stopped_word(nil), do: nil
  defp stopped_word(why) when is_atom(why), do: Atom.to_string(why)
  defp stopped_word(why), do: inspect(why)

  defp detail(""), do: "Every key was acknowledged."

  defp detail(_unconfirmed),
    do:
      "The unconfirmed keys may or may not have reached the call. Do not press them again; " <>
        "say what the menu does next."

  defp metadata(args, {:ok, %{success: false, error: error}}),
    do: %{key_count: key_count(args), error: error}

  defp metadata(args, _result), do: %{key_count: key_count(args)}

  defp key_count(%{"keys" => keys}) when is_binary(keys), do: String.length(keys)
  defp key_count(_args), do: 0

  defp sentence(:not_in_call), do: "#{@name} works only on a phone call's backend turn."

  defp sentence(:invalid_keys),
    do:
      "keys must be 1 to #{Limits.max_dtmf_keys()} keypad keys: the digits 0-9, * and #, " <>
        "or A-D."

  defp sentence(reason), do: "The keys were not pressed: #{inspect(reason)}"
end
