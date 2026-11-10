defmodule FermixCore.Home.EngineCeiling do
  @moduledoc """
  The newest Fermix a server may run (Always On's move back, design §6): a
  server always runs exactly the engine version of the computers it serves
  as primary for, from its first install and within a few minutes of each
  change after, so the home can always move back to one of them (a home a
  newer engine wrote is refused by an older one's restore,
  `FermixCore.Home.Archive`).

  The versions are the home's record of its computers
  (`FermixCore.Computers.Store`, M97): each computer's engine version as its
  `hello` said it (`app_version`, which a desktop engine fills with its own
  version; `FermixChannels.Mobile.Session`), and when the home last heard
  from it. That record is the one writer of the fact; this module only
  reads it, until M97's server-leads window replaces it.

  The ceiling (`ceiling/2`) is the oldest version among the computers seen
  in the last #{30} days: a computer unseen longer drops out. `nil` when none
  was seen. `home.status` answers it as `update_ceiling`, and the server's
  update installs exactly that version within five minutes, and restarts its
  engine unless a move is under way (`packaging/cloud/first-boot.sh`'s
  `fermix-update --follow`).
  """

  alias FermixCore.Computers.Store

  @window_s 30 * 86_400

  @doc "Where the versions are read from under `home` (the computers' records)."
  @spec dir(Path.t()) :: Path.t()
  def dir(home) when is_binary(home) and home != "", do: Store.dir(home)

  @doc """
  The oldest version among the computers seen in the window before `now`:
  `{:ok, nil}` when none was. A record Fermix did not write is named, never
  read as a version.
  """
  @spec ceiling(Path.t(), DateTime.t()) :: {:ok, String.t() | nil} | {:error, Store.error()}
  def ceiling(home, %DateTime{} = now) when is_binary(home) and home != "" do
    with {:ok, entries} <- Store.read_all(home) do
      entries
      |> Map.values()
      |> Enum.filter(&(is_binary(&1.engine_version) and seen_within?(&1, now)))
      |> Enum.map(& &1.engine_version)
      |> Enum.min_by(&Version.parse!/1, Version, fn -> nil end)
      |> then(&{:ok, &1})
    end
  end

  defp seen_within?(%{seen_at: %DateTime{} = seen_at}, now),
    do: DateTime.diff(now, seen_at) <= @window_s

  defp seen_within?(_entry, _now), do: false
end
