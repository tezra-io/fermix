defmodule FermixCore.NativeHost.Server do
  @moduledoc """
  The Unix-domain listener of `native_host.sock`, where the Fermix app attaches
  as the daemon's native host (M76 §4.4).

  Binds `<FERMIX_HOME>/native_host.sock` at 0600, the same class of surface as
  the browser host, companion, Realtime, ACP and daemon control sockets: same
  user, same machine, no network. While it serves, `Native.HostAvailability`
  records that an app could attach (`listening`), which is what lets a caller
  open the app on demand; its exit empties that record.

  One host at a time. An accepted socket is handed to a `NativeHost.Link`
  under the dynamic connection supervisor, numbered with the next connection
  id of this server; a second client while a link lives is answered with one
  `error` (`host_already_attached`) and closed.

  It is served only where `Native.Provider` is `:mac_app`, in a daemon
  (`FermixCore.Application`), and depends on no feature flag. A socket it
  cannot bind costs this surface and nothing else: `init/1` logs one
  actionable error naming the path and the reason and returns `:ignore`, and
  the daemon boots without it, so nothing rings on this Mac. It never retries
  and never falls back to another path or transport.
  """

  use GenServer

  require Logger

  alias FermixCore.Native.HostAvailability
  alias FermixCore.NativeHost.Link
  alias FermixCore.NativeHost.Protocol
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.SocketPath

  @accept_idle_ms 50
  @accept_retry_ms 1_000
  @socket_name "native_host.sock"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The socket path this listener binds: `native_host.sock` under `FERMIX_HOME`."
  @spec socket_path() :: String.t()
  def socket_path, do: Path.join(ConfigStore.fermix_home(), @socket_name)

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` runs on a supervisor shutdown: the listen
    # socket and its socket file are this process's resources.
    Process.flag(:trap_exit, true)

    path = Keyword.get(opts, :socket_path, socket_path())

    case bind(path) do
      {:ok, listen_socket} ->
        state = build_state(listen_socket, path, opts)
        :ok = HostAvailability.listening(state.host_availability, self())
        Process.send_after(self(), :accept, 0)
        Logger.info("native host socket listening on #{path}")
        {:ok, state}

      {:error, reason} ->
        Logger.error(refusal(reason, path))
        :ignore
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, @accept_idle_ms) do
      {:ok, socket} ->
        send(self(), :accept)
        {:noreply, accept_link(socket, state)}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("native host socket accept error: #{inspect(reason)}")
        Process.send_after(self(), :accept, @accept_retry_ms)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{link: {pid, ref}} = state),
    do: {:noreply, %{state | link: nil}}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listen_socket)
    _ = File.rm(state.socket_path)
    :ok
  end

  defp build_state(listen_socket, path, opts) do
    %{
      listen_socket: listen_socket,
      socket_path: path,
      connection_supervisor: Keyword.fetch!(opts, :connection_supervisor),
      link_opts: Keyword.get(opts, :link_opts, []),
      host_availability: Keyword.get(opts, :host_availability, HostAvailability),
      link: nil,
      next_connection_id: 1
    }
  end

  # Every step that can fail on an operator's machine, in the order the OS cares
  # about, each failure carrying the stage it came from.
  defp bind(path) do
    with :ok <- SocketPath.check(path),
         :ok <- stage(:mkdir, File.mkdir_p(Path.dirname(path))),
         :ok <- clear_stale_socket(path),
         {:ok, listen_socket} <- stage(:bind, listen(path)),
         :ok <- chmod_socket(path, listen_socket) do
      {:ok, listen_socket}
    end
  end

  defp stage(_stage, :ok), do: :ok
  defp stage(_stage, {:ok, value}), do: {:ok, value}
  defp stage(stage, {:error, reason}), do: {:error, {stage, reason}}

  defp listen(path) do
    :gen_tcp.listen(0, [
      :binary,
      {:active, false},
      {:ifaddr, {:local, path}},
      {:reuseaddr, true}
    ])
  end

  # An 0666 native host socket hands anyone on the machine the app's grants.
  defp chmod_socket(path, listen_socket) do
    case File.chmod(path, 0o600) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = :gen_tcp.close(listen_socket)
        _ = File.rm(path)
        {:error, {:chmod, reason}}
    end
  end

  defp refusal({:path_too_long, bytes, limit}, path) do
    "the native host socket is disabled for this boot: " <>
      SocketPath.refusal("native host socket", bytes, limit) <> ". Path: #{path}"
  end

  defp refusal({:another_native_host_socket_running, _path}, path) do
    "the native host socket is disabled for this boot: another daemon is already listening " <>
      "on #{path}. Stop it, or give this daemon its own FERMIX_HOME, then restart."
  end

  defp refusal({:stale_socket_unlink_failed, reason, _path}, path) do
    "the native host socket is disabled for this boot: a stale socket file at #{path} " <>
      "could not be removed (#{inspect(reason)}). Delete it and restart."
  end

  defp refusal({stage, reason}, path) when reason in [:eacces, :eperm] do
    "the native host socket is disabled for this boot: permission denied (#{stage}) on " <>
      "#{path}. Check the ownership and mode of #{Path.dirname(path)}, then restart."
  end

  defp refusal({stage, reason}, path) do
    "the native host socket is disabled for this boot: #{path} could not be opened, " <>
      "#{stage} failed with #{inspect(reason)}. Everything else on this daemon is running."
  end

  # Probe before unlinking. A live listener answers, and stealing its path would
  # leave it serving an app at an address nobody can reach again; a stale file
  # from a crashed daemon refuses and is removed.
  defp clear_stale_socket(path) do
    cond do
      not File.exists?(path) -> :ok
      live_socket?(path) -> {:error, {:another_native_host_socket_running, path}}
      true -> unlink_stale(path)
    end
  end

  defp live_socket?(path) do
    case :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, {:active, false}], 500) do
      {:ok, socket} ->
        _ = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp unlink_stale(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:stale_socket_unlink_failed, reason, path}}
    end
  end

  defp accept_link(socket, %{link: {_pid, _ref}} = state) do
    Logger.warning("native host socket refusing a client: a host is already attached")

    with {:ok, line} <-
           Protocol.encode_daemon_frame("error", %{"reason" => "host_already_attached"}) do
      _ = :gen_tcp.send(socket, line)
    end

    _ = :gen_tcp.close(socket)
    state
  end

  defp accept_link(socket, state) do
    opts =
      Keyword.merge(state.link_opts,
        socket: socket,
        connection_id: state.next_connection_id,
        host_availability: state.host_availability
      )

    case DynamicSupervisor.start_child(state.connection_supervisor, {Link, opts}) do
      {:ok, pid} ->
        hand_over(socket, pid, state)

      {:error, reason} ->
        Logger.error("native host socket could not start a link: #{inspect(reason)}")
        _ = :gen_tcp.close(socket)
        state
    end
  end

  # After this the link's exit closes the fd on every path, so a dead reader
  # can never leave the app hanging without EOF.
  defp hand_over(socket, pid, state) do
    case :gen_tcp.controlling_process(socket, pid) do
      :ok ->
        send(pid, :socket_handover)
        link = {pid, Process.monitor(pid)}
        %{state | link: link, next_connection_id: state.next_connection_id + 1}

      {:error, reason} ->
        Logger.error("native host socket handover failed: #{inspect(reason)}")
        _ = DynamicSupervisor.terminate_child(state.connection_supervisor, pid)
        _ = :gen_tcp.close(socket)
        state
    end
  end
end
