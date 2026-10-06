defmodule FermixChannels.Voice.Supervisor do
  @moduledoc """
  Owns the voice bridge's routing Registry
  (MILESTONE_41_OPENAI_LIVE_VOICE.md §7).

  Two children. A unique-keys `Registry` mapping a call id (and each
  `{call_id, delegation_id}` pair under it) to the Live session that owns it.
  That is how `FermixChannels.Channels.Voice`'s per-turn closures find the
  session whose delegation they are answering, and how a late event for a closed
  call is recognised as late. Then `Voice.Detached`, the owner of the tasks
  that outlive their call (M56 §4.6), which registers in that registry and so
  starts after it, and outlives every session.

  Started by `FermixChannels.Application` AFTER `Gateway.Queue`, because the
  bridge ingests through the queue: a delegation accepted before the queue is
  up has nowhere to run. There is no transport child — the Live session calls
  `FermixChannels.Voice.Bridge` in process, so the "voice" registry entry names
  no child at all.

  Registry entries are owned by the Live session process, so a session that dies
  without closing its call leaves nothing behind: ERTS unregisters every key the
  dead process held.
  """

  use Supervisor

  alias FermixChannels.Channels.Voice
  alias FermixChannels.Voice.Detached

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, Voice.registry())

    Supervisor.init(
      [
        {Registry, keys: :unique, name: registry},
        {Detached, Keyword.get(opts, :detached, [])}
      ],
      strategy: :one_for_one
    )
  end
end
