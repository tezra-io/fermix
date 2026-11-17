defmodule FermixCore.PhoneCalls.Grants do
  @moduledoc """
  Which tools a phone call's brief may grant its backend turns (M94 §06,
  §11), decided once, here, and nowhere else.

  A brief's `tool_grants` names the tools a call's backend turn may use to
  answer the person called. That turn runs for an untrusted speaker, so a
  grant is limited to tools that only read public information: they write,
  send, execute, browse a page, drive a computer, start an agent and touch
  memory not at all, return none of the owner's own data, are neither
  owner-only nor access-sensitive, and are never the `phone_call` tool. Two
  qualify today, both read-only lookups of the open web:

    * `web_search`: search results for a query the turn writes;
    * `place_search`: a provider's data on a named place.

  The list is explicit rather than derived from capability metadata, so a
  tool added later is never grantable until it is named here: its test holds
  each name to that rule over the capability the built-in actually builds.

  `resolve/1` answers the grantable set, or a refusal of its own kind naming
  every rejected tool and why: the call's own controls (`:call_control`,
  `PhoneCalls.Tools.controls/0`, which
  every call has and no brief grants), the tool that places calls
  (`:places_calls`), and everything else (`:not_grantable`). Admission
  refuses a brief it rejects before any row or attempt exists
  (`PhoneCalls.Manager`), and each backend turn resolves it again
  (`Agents.PhoneCallTurn`), so a stored brief can never widen a turn.
  """

  alias FermixCore.PhoneCalls.Tools
  alias FermixCore.Tools.PhoneCall

  @grantable ["web_search", "place_search"]

  @type why :: :call_control | :places_calls | :not_grantable
  @type refusal :: {:tools_not_grantable, [{String.t(), why()}, ...]}

  @doc "The tools a brief may grant."
  @spec grantable() :: [String.t(), ...]
  def grantable, do: @grantable

  @doc """
  The grantable set for `tool_grants`, in its order with repeats dropped, or
  the refusal naming each rejected tool and why.
  """
  @spec resolve([String.t()]) :: {:ok, [String.t()]} | {:error, refusal()}
  def resolve(tool_grants) when is_list(tool_grants) do
    names = Enum.uniq(tool_grants)

    case for(name <- names, why = rejection(name), do: {name, why}) do
      [] -> {:ok, names}
      rejected -> {:error, {:tools_not_grantable, rejected}}
    end
  end

  defp rejection(name) when is_binary(name) do
    cond do
      name in @grantable -> nil
      name in Tools.control_names() -> :call_control
      name == PhoneCall.name() -> :places_calls
      true -> :not_grantable
    end
  end

  defp rejection(other),
    do: raise(ArgumentError, "a tool grant must be a tool name, got: #{inspect(other)}")
end
