defmodule FermixCore.Home.Leave do
  @moduledoc """
  Disconnect this computer (M97 §3.3, `computer.disconnect`): a linked
  computer leaves the home it is linked to.

  It tells the home first: `mobile.devices.revoke {device_id, confirmed:
  true}` over the link (`:forward`, the rail's `Home.Link.forward/2`), so the
  server forgets this computer's row and its record of what it offered, and
  closes its session. Closing it can cut off the answer to this very
  request, so a request that ends with the link saying the server no longer
  knows this computer (`DesktopLink.revoked?/1`, which the relay writes
  before it answers the request the ending cut off) was taken: so was one
  sent after the owner removed this computer there. Any other server that
  cannot be told (out of reach, or one that refuses) is said, and nothing
  changes here unless the owner confirmed (`:confirmed`): then this computer
  leaves anyway, and the server lists it until it is removed there.

  Then this computer lets go of everything that linked it, its relay first,
  whatever its link says (`Home.Unlink.let_go/4`, `:any`): its key, what
  Fermix on the server may use here, its role, and last its link. A
  computer that never moved a home (one that joined) is the primary of its
  own home again; the one a home moved from keeps its moved marker and the
  device role, retired, and its own copies of the server's backups
  (`Home.Unlink.role_after/1`). Then the engine restarts.

  The link is the record that a disconnect is unfinished: it goes last, and
  every step before it is safe to repeat, so one that fails part-way leaves
  this computer linked and asking again finishes the job. Which role it
  ends in is read first, before the server is told, so a moved marker that
  cannot be read refuses before anything changes.

  `opts`: `:forward` (required, the link), `:confirmed` (boolean), `:restart`
  (0-arity, in place of `Management.Lifecycle.restart_self/0`), and
  `:key_opts` and `:release`, handed to `Home.Unlink.let_go/4`.
  """

  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Unlink
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Management.Protocol

  require Logger

  @type error :: :not_linked | :not_told | {:link, DesktopLink.error()} | Unlink.error()

  @doc """
  Disconnects the computer at `home` (see the moduledoc): `{:ok, told?}`,
  whether the server took it, or why nothing changed.
  """
  @spec disconnect(Path.t(), keyword()) :: {:ok, boolean()} | {:error, error()}
  def disconnect(home, opts) when is_binary(home) and home != "" and is_list(opts) do
    forward = Keyword.fetch!(opts, :forward)

    with {:ok, link} <- linked(home),
         {:ok, _role} <- Unlink.role_after(home),
         {:ok, told?} <- tell(forward, link, home, opts),
         :ok <- Unlink.let_go(home, link, :any, Keyword.take(opts, [:key_opts, :release])) do
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

  def error_sentence({:link, reason}), do: DesktopLink.error_sentence(reason)
  def error_sentence(reason), do: Unlink.error_sentence(reason)

  @doc "Every sentence a disconnect shows, for the copy rules: its own and its letting go's."
  @spec sentences() :: [String.t()]
  def sentences,
    do: Enum.map([:not_linked, :not_told], &error_sentence/1) ++ Unlink.sentences()

  defp linked(home) do
    case DesktopLink.read(home) do
      {:ok, link} -> {:ok, link}
      {:error, {:file, _path, :enoent}} -> {:error, :not_linked}
      {:error, reason} -> {:error, {:link, reason}}
    end
  end

  # The server forgets this computer; one that cannot be told stops here
  # unless the owner confirmed.
  defp tell(forward, link, home, opts) do
    request = %{
      request_id: "computer-disconnect",
      protocol_version: Protocol.protocol_version(),
      method: "mobile.devices.revoke",
      params: %{"device_id" => link.device_id, "confirmed" => true}
    }

    case forward.(request, []) do
      {:ok, _revoked} -> {:ok, true}
      {:error, code, _details} -> unanswered(code, DesktopLink.revoked?(home), opts)
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
end
