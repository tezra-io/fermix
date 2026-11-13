defmodule FermixChannels.Companion.ChecklistNotifier do
  @moduledoc """
  How a committed change to the owner's lists, or trips, reaches the Mac
  (M85 §07, M89 §07).

  The channels app registers this module as core's `:checklists_notifier` at
  boot, and `FermixCore.Kept.Notify` calls `changed/1` right after the store
  commits any change, whoever made it: the model, a job or a device.
  It tells every connection of the companion socket what changed, by kind
  (`{:checklists_changed, lists}`, `{:trips_changed, trips}`), with their new
  revs and what a device's add or create made, and every phone's list channel
  (registered under `{:lists, profile}`, M85 E4); each connection decides
  what it holds and pushes it (`Companion.Kept`). A connection that holds no
  trip lets a trip's change pass. It runs in the caller's process and only
  sends messages, so a change never waits on a socket. With the companion
  socket down there is nobody to tell.
  """

  alias FermixChannels.Channels.Companion

  @profile "main"

  @doc "Tells the connections of `registry` (the companion socket's) that lists or trips changed."
  @spec changed(map(), atom()) :: :ok
  def changed(changes, registry \\ Companion.registry())

  def changed(%{lists: [_ | _] = lists}, registry) when is_atom(registry),
    do: tell_all(registry, {:checklists_changed, lists})

  def changed(%{trips: [_ | _] = trips}, registry) when is_atom(registry),
    do: tell_all(registry, {:trips_changed, trips})

  defp tell_all(registry, message) do
    if Process.whereis(registry) do
      for key <- [@profile, {:lists, @profile}],
          do: Registry.dispatch(registry, key, &tell(&1, message))
    end

    :ok
  end

  defp tell(entries, message),
    do: Enum.each(entries, fn {pid, _version} -> send(pid, message) end)
end
