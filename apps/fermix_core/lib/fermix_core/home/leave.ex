defmodule FermixCore.Home.Leave do
  @moduledoc """
  Disconnect this computer (M97 §3.3, `computer.disconnect`): a linked
  computer leaves the home it is linked to.

  It tells the home first: `mobile.devices.revoke {device_id, confirmed:
  true}` over the link (`:forward`, the rail's `Home.Link.forward/2`), so the
  server forgets this computer's row and its record of what it offered, and
  closes its session. Closing it can cut off the answer to this very
  request, so a request that ends with the link saying the server no longer
  knows this computer (`:link_status`, the relay's `revoked`) was taken: so
  was one sent after the owner removed this computer there. Any other
  server that cannot be told (out of reach, or one that refuses) is said,
  and nothing changes here unless the owner confirmed (`:confirmed`): then
  this computer leaves anyway, and the server lists it until it is removed
  there.

  Then this computer lets go of everything that linked it: its key, from
  the store its link names, and only while the item holds that key (another
  home's under the same profile stays, `ComputerKey`); what Fermix on the
  server may use here (`[fermix_core.computer]` in `machine.toml`,
  `Computers.Switches`); its role; and last its link
  (`device/desktop.json`). A computer that never moved a home (one that
  joined) is the primary of its own home again; the one a home moved from
  keeps its moved marker and the device role, retired, and its own copies
  of the server's backups. Then the computer history mark that home left is
  forgotten (`Home.Join.forget_history_mark/1`), and the engine restarts.

  The link is the record that a disconnect is unfinished: it goes last, and
  every step before it is safe to repeat, so one that fails part-way leaves
  this computer linked and asking again finishes the job. Which role it
  ends in is read first, so a moved marker that cannot be read refuses
  before anything changes.

  `opts`: `:forward` (required, the link), `:confirmed` (boolean), `:restart`
  (0-arity, in place of `Management.Lifecycle.restart_self/0`), `:key_opts`
  (handed to `ComputerKey`) and `:link_status` (0-arity, in place of
  `Home.Link.impl().status/0`).
  """

  alias FermixCore.Computers.Switches
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Join
  alias FermixCore.Home.Link
  alias FermixCore.Home.Moved
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Protocol
  alias FermixCore.Setup.ConfigStore

  require Logger

  @type error ::
          :not_linked
          | :not_told
          | {:computer_key, ComputerKey.error()}
          | {:link, DesktopLink.error()}
          | {:moved, Moved.error()}
          | {:file, Path.t(), File.posix()}
          | {:config, term()}

  @doc """
  Disconnects the computer at `home` (see the moduledoc): `{:ok, told?}`,
  whether the server took it, or why nothing changed.
  """
  @spec disconnect(Path.t(), keyword()) :: {:ok, boolean()} | {:error, error()}
  def disconnect(home, opts) when is_binary(home) and home != "" and is_list(opts) do
    forward = Keyword.fetch!(opts, :forward)

    with {:ok, link} <- linked(home),
         {:ok, role} <- role_after(home),
         {:ok, told?} <- tell(forward, link, opts),
         :ok <- forget_key(home, link, Keyword.get(opts, :key_opts, [])),
         :ok <- config(Switches.forget(home)),
         :ok <- put_role(home, role),
         :ok <- remove_link(home) do
      :ok = Join.forget_history_mark(home)
      :ok = Keyword.get(opts, :restart, &Lifecycle.restart_self/0).()
      {:ok, told?}
    end
  end

  @doc "The sentence a person is shown for an error of this module."
  @spec error_sentence(error()) :: String.t()
  def error_sentence(:not_linked), do: "This computer is not connected to a Fermix."

  def error_sentence(:not_told),
    do:
      "Fermix could not tell your server. Disconnect anyway? Your server lists this computer " <>
        "until you remove it there."

  def error_sentence({:computer_key, reason}), do: ComputerKey.error_sentence(reason)
  def error_sentence({:link, reason}), do: DesktopLink.error_sentence(reason)

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
          :not_linked,
          :not_told,
          {:moved, {:file, "moved.json", :eacces}},
          {:file, "desktop.json", :eacces},
          {:config, :eacces}
        ],
        &error_sentence/1
      )

  defp linked(home) do
    case DesktopLink.read(home) do
      {:ok, link} -> {:ok, link}
      {:error, {:file, _path, :enoent}} -> {:error, :not_linked}
      {:error, reason} -> {:error, {:link, reason}}
    end
  end

  # The server forgets this computer; one that cannot be told stops here
  # unless the owner confirmed.
  defp tell(forward, link, opts) do
    request = %{
      request_id: "computer-disconnect",
      protocol_version: Protocol.protocol_version(),
      method: "mobile.devices.revoke",
      params: %{"device_id" => link.device_id, "confirmed" => true}
    }

    case forward.(request, []) do
      {:ok, _revoked} -> {:ok, true}
      {:error, code, _details} -> unanswered(code, forgotten?(opts), opts)
    end
  end

  defp unanswered(_code, true, _opts), do: {:ok, true}

  defp unanswered(code, false, opts) do
    if Keyword.get(opts, :confirmed, false) do
      Logger.warning("disconnect: the server was not told (#{code}); disconnected anyway")
      {:ok, false}
    else
      Logger.warning("disconnect: the server was not told (#{code}); nothing changed")
      {:error, :not_told}
    end
  end

  # Whether the server no longer knows this computer: it ended the session
  # as revoked, which it does as it takes the request, or did before.
  defp forgotten?(opts) do
    status = Keyword.get(opts, :link_status, fn -> Link.impl().status() end)
    match?(%{primary: %{status: :revoked}}, status.())
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

  # A computer that joined is its own home's primary again; the one a home
  # moved from stays retired, in the device role its marker needs. Read
  # before anything changes, so a marker that cannot be read refuses then.
  defp role_after(home) do
    case Moved.read(home) do
      :absent -> {:ok, :primary}
      {:ok, _marker} -> {:ok, :device}
      {:error, reason} -> unread_marker(reason)
    end
  end

  defp unread_marker(reason) do
    Logger.error("disconnect: the moved marker could not be read: #{inspect(reason)}")
    {:error, {:moved, reason}}
  end

  defp put_role(_home, :device), do: :ok
  defp put_role(home, :primary), do: config(ConfigStore.put_engine_role(home, :primary))

  defp config(:ok), do: :ok
  defp config({:error, reason}), do: {:error, {:config, reason}}
end
