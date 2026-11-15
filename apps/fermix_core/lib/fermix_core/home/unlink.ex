defmodule FermixCore.Home.Unlink do
  @moduledoc """
  This computer lets go of its link to a home's server, on this computer
  alone (M97 §3.3): the local half of a disconnect (`Home.Leave`), which a
  join with a new code also runs on a link its server revoked
  (`Home.Join.start/3`), where there is no server to tell.

  `let_go/4` first has the desktop relay stop for good (`Home.Link`'s
  `release_link/1`): until the engine restarts it dials nothing and writes
  nothing of the link, so no session that comes up later writes back a link
  this computer let go of. A join asks that only while the relay's link still
  holds its server's word that it no longer knows this computer
  (`:revoked`): one whose session came up since, its server knowing this
  computer again, keeps its link (`:known`). A disconnect asks it whatever
  the link says (`:any`). No relay running (a terminal, Fermix stopped) has
  nothing to stop.

  Then it lets go of everything that linked this computer: its key, from the
  store the link names, and only while the item holds that key (another
  home's under the same profile stays, `ComputerKey`); what Fermix on the
  server may use here (`[fermix_core.computer]` in `machine.toml`,
  `Computers.Switches`); its role (`role_after/1`); and last the link
  (`device/desktop.json`). Then the computer history mark that home left is
  forgotten (`forget_history_mark/1`).

  The link is the record that letting go is unfinished: it goes last, and
  every step before it is safe to repeat, so one that fails part-way leaves
  this computer linked, and asking again finishes the job. Which role it ends
  in is read first, so a moved marker that cannot be read refuses before
  anything changes.

  `opts`: `:key_opts` (handed to `ComputerKey`) and `:release` (1-arity, in
  place of `Home.Link.impl().release_link/1`).
  """

  require Logger

  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Computers.Switches
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Link
  alias FermixCore.Home.Moved
  alias FermixCore.Setup.ConfigStore

  @type error ::
          :known
          | :unanswered
          | {:computer_key, ComputerKey.error()}
          | {:moved, Moved.error()}
          | {:file, Path.t(), File.posix()}
          | {:config, term()}

  @doc """
  Lets go of the link `link` under `home` (see the moduledoc): `:revoked`
  for a join, `:any` for a disconnect.
  """
  @spec let_go(Path.t(), DesktopLink.t(), :revoked | :any, keyword()) :: :ok | {:error, error()}
  def let_go(home, %{device_id: _id} = link, which, opts)
      when is_binary(home) and home != "" and which in [:revoked, :any] and is_list(opts) do
    with {:ok, role} <- role_after(home),
         :ok <- release(which, opts),
         :ok <- forget_key(home, link, Keyword.get(opts, :key_opts, [])),
         :ok <- config(Switches.forget(home)),
         :ok <- put_role(home, role),
         :ok <- remove_link(home) do
      forget_history_mark(home)
    end
  end

  @doc """
  The role `home` takes once it lets go of its link, the one rule for it: a
  computer that never moved a home (one that joined) is the primary of its
  own home again; the one a home moved from stays retired, in the device role
  its moved marker needs. A marker that cannot be read is
  `{:error, {:moved, reason}}`, logged.
  """
  @spec role_after(Path.t()) :: {:ok, :primary | :device} | {:error, error()}
  def role_after(home) when is_binary(home) and home != "" do
    case Moved.read(home) do
      :absent -> {:ok, :primary}
      {:ok, _marker} -> {:ok, :device}
      {:error, reason} -> unread_marker(reason)
    end
  end

  @doc """
  Forgets which home this machine's computer history mark counts
  (`ComputerHistory.Spool.forget_home/1`), as a join and a disconnect do. The
  home's identity carried with each delivery decides on its own, so a store
  that cannot be opened is logged and never stops the step that asked.
  """
  @spec forget_history_mark(Path.t()) :: :ok
  def forget_history_mark(home) when is_binary(home) and home != "" do
    case Spool.forget_home(home) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("this computer's history mark could not be forgotten: #{inspect(reason)}")
    end
  end

  @doc "The sentence a person is shown for an error of this module."
  @spec error_sentence(error()) :: String.t()
  def error_sentence(:known),
    do: "Your server knows this computer again, so it keeps its link to it."

  def error_sentence(:unanswered),
    do:
      "Fermix could not stop this computer's link to your server in time, so nothing " <>
        "changed. Try again."

  def error_sentence({:computer_key, reason}), do: ComputerKey.error_sentence(reason)

  def error_sentence({:moved, _reason}),
    do:
      "Fermix could not read whether your Fermix moved from this computer, so nothing " <>
        "changed. Its log says why."

  def error_sentence({:file, _path, reason}),
    do: "Fermix could not remove this computer's link (#{:file.format_error(reason)})."

  def error_sentence({:config, _reason}),
    do: "Fermix could not change this computer's settings file. Its log says why."

  @doc "Every sentence of this module's own, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences,
    do:
      Enum.map(
        [
          :known,
          :unanswered,
          {:moved, {:file, "moved.json", :eacces}},
          {:file, "desktop.json", :eacces},
          {:config, :eacces}
        ],
        &error_sentence/1
      )

  defp release(which, opts) do
    release = Keyword.get(opts, :release, fn kind -> Link.impl().release_link(kind) end)

    case release.(which) do
      :ok -> :ok
      {:error, reason} when reason in [:known, :unanswered] -> {:error, reason}
    end
  end

  # Only this computer's own key: read first, so an item that holds another
  # home's key under the same profile stays.
  defp forget_key(home, link, key_opts) do
    case ComputerKey.read(home, key_opts) do
      {:ok, %{public: public}} ->
        key(ComputerKey.delete(home, link.key, [public: public] ++ key_opts))

      {:error, {:missing, _store}} ->
        key(ComputerKey.delete(home, nil, key_opts))

      {:error, :not_moved} ->
        key(ComputerKey.delete(home, nil, key_opts))

      {:error, reason} ->
        {:error, {:computer_key, reason}}
    end
  end

  defp key(:ok), do: :ok
  defp key({:error, reason}), do: {:error, {:computer_key, reason}}

  defp remove_link(home) do
    file = DesktopLink.path(home)

    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp unread_marker(reason) do
    Logger.error("letting go of the link: the moved marker could not be read: #{inspect(reason)}")
    {:error, {:moved, reason}}
  end

  defp put_role(_home, :device), do: :ok
  defp put_role(home, :primary), do: config(ConfigStore.put_engine_role(home, :primary))

  defp config(:ok), do: :ok
  defp config({:error, reason}), do: {:error, {:config, reason}}
end
