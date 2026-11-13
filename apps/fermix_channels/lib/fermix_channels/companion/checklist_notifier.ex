defmodule FermixChannels.Companion.ChecklistNotifier do
  @moduledoc """
  How a committed change to the owner's lists reaches the Mac (M85 §07).

  The channels app registers this module as core's `:checklists_notifier` at
  boot, and `FermixCore.Kept.Notify` calls `changed/1` right after the store
  commits any change, whoever made it: the model, a job or a device.
  It tells every connection of the companion socket which lists changed, with
  their new revs and what a device's add or create made, and every phone's
  list channel (registered under `{:lists, profile}`, M85 E4); each connection
  decides what it holds and pushes it (`Companion.Kept`). It runs in the
  caller's process and only sends messages, so a change never waits on a
  socket. With the companion socket down there is nobody to tell.
  """

  alias FermixChannels.Channels.Companion

  @profile "main"

  @doc "Tells the connections of `registry` (the companion socket's) that lists changed."
  @spec changed(map(), atom()) :: :ok
  def changed(%{lists: [_ | _] = lists}, registry \\ Companion.registry())
      when is_atom(registry) do
    if Process.whereis(registry) do
      for key <- [@profile, {:lists, @profile}],
          do: Registry.dispatch(registry, key, &tell(&1, {:checklists_changed, lists}))
    end

    :ok
  end

  defp tell(entries, message),
    do: Enum.each(entries, fn {pid, _version} -> send(pid, message) end)
end
