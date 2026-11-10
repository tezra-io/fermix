defmodule FermixCore.Computers.Origin do
  @moduledoc """
  What kind of turn asked a computer to do something (M97 §6.1): the
  `origin` an `invoke_open` carries, so the computer applies its own rules to
  it (computer use stays attended-only there as here).

  `of/1` is the one resolver, over the same facts every other gate reads,
  so they never disagree:

    * a delegated worker (`FermixCore.Temporal.Access.worker?/1`: a
      subagent or a skill at any depth) is `worker`, whatever surface it
      runs on;
    * a run a cue woke (`trigger: "cue"`) is `cue`; any other job run
      (`trigger` `schedule`, `manual`, `watcher`) is `scheduled`;
    * a coding run's notice re-entering a chat (`harness_continuation_depth`
      above 0) is `background`: the owner did not type it;
    * then the surface (`computer_use_origin`, `TurnRunner`'s one resolver):
      `voice` for a live call, `chat` for an interactive turn, `background`
      for one nobody watches;
    * anything else is `background`: absence is never read as authority.

  `computer` is no turn's: it is a computer asking its server for one of the
  home's services, which only the wire carries (`wire_origins/0`).

  The origin is the server's word. Checking it on the computer guards
  against a bug on the server, not against a server that was taken over.
  Pure.
  """

  alias FermixCore.Temporal.Access

  @typedoc "What kind of turn asked."
  @type t :: :chat | :voice | :scheduled | :cue | :worker | :background

  @origins [:chat, :voice, :scheduled, :cue, :worker, :background]
  @wire_origins @origins ++ [:computer]
  @words Map.new(@wire_origins, &{Atom.to_string(&1), &1})
  @scheduled_triggers ~w(schedule manual watcher)

  @doc "Every origin a turn can have."
  @spec origins() :: [t()]
  def origins, do: @origins

  @doc "Every origin the wire carries: a turn's, and a computer's own request."
  @spec wire_origins() :: [t() | :computer]
  def wire_origins, do: @wire_origins

  @doc "The origin of the turn whose loop context is `context` (the moduledoc)."
  @spec of(map()) :: t()
  def of(context) when is_map(context) do
    cond do
      Access.worker?(context) -> :worker
      Map.get(context, :trigger) == "cue" -> :cue
      Map.get(context, :trigger) in @scheduled_triggers -> :scheduled
      continuation?(context) -> :background
      true -> surface(Map.get(context, :computer_use_origin))
    end
  end

  @doc "The origin a wire word names, or `:error`."
  @spec from_wire(term()) :: {:ok, t() | :computer} | :error
  def from_wire(word), do: Map.fetch(@words, word)

  @doc "Whether `origin` is a turn's, which names its turn on the wire."
  @spec turn?(t() | :computer) :: boolean()
  def turn?(origin), do: origin in @origins

  @doc "Whether `origin` is a turn the owner is in now: a chat or a call."
  @spec attended?(t() | :computer) :: boolean()
  def attended?(origin), do: origin in [:chat, :voice]

  defp surface(:voice), do: :voice
  defp surface(:interactive), do: :chat
  defp surface(_unattended_or_absent), do: :background

  # A coding run's notice re-entering its chat: any depth that is not an
  # absent or zero one.
  defp continuation?(context) do
    case Map.get(context, :harness_continuation_depth) do
      nil -> false
      0 -> false
      _deeper_or_malformed -> true
    end
  end
end
