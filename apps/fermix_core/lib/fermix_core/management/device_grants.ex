defmodule FermixCore.Management.DeviceGrants do
  @moduledoc """
  The folders this computer lets its primary read (M75 §11), in the
  `device.*` family: `device.grants.list` and `device.grants.remove {path}`.

  After a move, the owner approves a `device_action` `grant_read` on a card
  on the primary, and the desktop records the folder in its own read grants
  (`FermixCore.Home.ReadGrants`), showing a notification as it does. These
  methods are device-class (`Management.Placement`): the engine on this
  computer answers them and never forwards them, so the owner sees and
  removes what the server may read here from this computer's app or terminal
  (`fermix device grants`). A grant removed holds for the next `read_file` or
  `list_directory` the server asks for, which read the grants anew each time.
  `device.grants.remove` is an owner decision on `daemon.sock`. An engine
  that never moved holds no grant and lists none.

  - `device.grants.list` answers `{grants: [{path, granted_at}], sentence}`,
    oldest first.
  - `device.grants.remove {path}` removes the grant of `path`, as it was
    listed or by another name for the same folder, and answers
    `{removed, grants, sentence}` with the grants left. A folder this
    computer grants nothing for is `invalid_params` on `path`, with its
    sentence.

  Test seam in `opts`: `:home` (this engine's home).
  """

  alias FermixCore.Home.ReadGrants
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Setup.ConfigStore

  require Logger

  @capability "device"
  @owner_sentence "Only the owner can change what the server may read on this computer: use " <>
                    "the Fermix app or your own terminal."
  @not_granted "This computer has no read grant for that folder."
  @unreadable "This computer's read grants could not be read. See the daemon log."
  @not_removed "The read grant could not be removed. See the daemon log."

  @doc "The capability a refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc """
  The sentence `daemon.sock` answers when a process Fermix started (or one it
  cannot place) asks to remove a read grant: the owner's decision.
  """
  @spec owner_only_sentence() :: String.t()
  def owner_only_sentence, do: @owner_sentence

  @doc "Every fixed sentence this family answers, for the copy checks."
  @spec sentences() :: [String.t()]
  def sentences do
    [@owner_sentence, @not_granted, @unreadable, @not_removed, removed_sentence()] ++
      Enum.map([0, 1, 2], &listed_sentence/1)
  end

  @doc "`device.grants.list`."
  @spec list(keyword()) :: {:ok, map()} | {:error, term()}
  def list(opts \\ []) when is_list(opts) do
    case ReadGrants.list(home(opts)) do
      {:ok, grants} -> {:ok, list_view(grants)}
      {:error, reason} -> unreadable(reason)
    end
  end

  @doc "`device.grants.remove`: `path` is an absolute path, as the router checked it."
  @spec remove(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove("/" <> _rest = path, opts \\ []) when is_list(opts) do
    names = Enum.uniq([path, PathPolicy.canonical_path(path)])

    case ReadGrants.remove(home(opts), names) do
      {:ok, left} ->
        {:ok, %{"removed" => path, "grants" => rows(left), "sentence" => removed_sentence()}}

      {:error, :not_granted} ->
        {:error, {:invalid_params, "path", @not_granted}}

      {:error, {:invalid_read_grants, _file} = reason} ->
        unreadable(reason)

      {:error, reason} ->
        Logger.error("device.grants.remove: the grants were not written: #{inspect(reason)}")
        {:error, {:unavailable, @capability, @not_removed}}
    end
  end

  defp list_view(grants),
    do: %{"grants" => rows(grants), "sentence" => listed_sentence(length(grants))}

  defp rows(grants),
    do: Enum.map(grants, &%{"path" => &1.path, "granted_at" => &1.granted_at})

  defp listed_sentence(0),
    do: "The server may read nothing on this computer beyond what its sandbox allows."

  defp listed_sentence(1),
    do: "The server may read 1 folder on this computer beyond what its sandbox allows."

  defp listed_sentence(count),
    do: "The server may read #{count} folders on this computer beyond what its sandbox allows."

  defp removed_sentence,
    do: "The server can no longer read that folder on this computer."

  defp unreadable(reason) do
    Logger.error("device.grants: the read grants could not be read: #{inspect(reason)}")
    {:error, {:unavailable, @capability, @unreadable}}
  end

  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
end
