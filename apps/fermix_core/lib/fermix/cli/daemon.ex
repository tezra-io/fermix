defmodule Fermix.CLI.Daemon do
  @moduledoc """
  Control-socket listener for `fermix status` and `fermix stop`.

  Listens on a Unix domain socket at `~/.fermix/daemon.sock` (user
  scope) or `/var/run/fermix.sock` (system scope) and serves a tiny
  newline-delimited JSON request/response protocol. Two methods:

      {"method":"status"}    -> {"status":"ok","version":"...","uptime_ms":N}
      {"method":"shutdown"}  -> {"status":"shutting_down"}  then :init.stop()

  Started only inside `fermix run` (the supervision tree branches on
  `:fermix_core, :daemon_socket_enabled`). Stale sockets from prior
  crashes are removed on boot; double-binding fails fast on
  EADDRINUSE rather than silently overwriting.
  """

  use GenServer

  alias FermixCore.Trace

  require Logger

  @recv_timeout_ms 5_000
  @accept_idle_ms 200

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    socket_path = Keyword.get(opts, :socket_path, default_socket_path())
    task_supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)

    File.mkdir_p!(Path.dirname(socket_path))

    case clear_stale_socket(socket_path) do
      :ok -> do_listen(socket_path, task_supervisor)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp do_listen(socket_path, task_supervisor) do
    listen_opts = [
      :binary,
      {:active, false},
      {:ifaddr, {:local, socket_path}},
      {:packet, :line},
      {:reuseaddr, true}
    ]

    case :gen_tcp.listen(0, listen_opts) do
      {:ok, listen_socket} ->
        File.chmod!(socket_path, 0o600)
        Logger.info("Daemon control socket listening at #{socket_path}")
        Process.send_after(self(), :accept, 0)

        {:ok,
         %{
           listen_socket: listen_socket,
           socket_path: socket_path,
           task_supervisor: task_supervisor,
           started_at_ms: System.monotonic_time(:millisecond)
         }}

      {:error, reason} ->
        {:stop, {:listen_failed, reason, socket_path}}
    end
  end

  # If the socket file exists, probe it before deleting. A live daemon
  # answers; a stale socket from a previous crash refuses or errors.
  # Unlinking a live socket would let us bind the same path while the
  # original daemon stays running but unreachable via status/stop.
  defp clear_stale_socket(socket_path) do
    cond do
      not File.exists?(socket_path) -> :ok
      live_daemon?(socket_path) -> {:error, {:another_daemon_running, socket_path}}
      true -> rm_stale(socket_path)
    end
  end

  defp live_daemon?(socket_path) do
    case :gen_tcp.connect(
           {:local, to_charlist(socket_path)},
           0,
           [:binary, {:active, false}, {:packet, :line}],
           500
         ) do
      {:ok, conn} ->
        _ = :gen_tcp.close(conn)
        true

      {:error, _} ->
        false
    end
  end

  defp rm_stale(socket_path) do
    case File.rm(socket_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:stale_socket_unlink_failed, reason, socket_path}}
    end
  end

  @impl true
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, @accept_idle_ms) do
      {:ok, conn} ->
        spawn_handler(state, conn)
        send(self(), :accept)
        {:noreply, state}

      {:error, :timeout} ->
        send(self(), :accept)
        {:noreply, state}

      {:error, :closed} ->
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Daemon accept error: #{inspect(reason)}")
        Process.send_after(self(), :accept, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{listen_socket: socket, socket_path: path}) do
    _ = :gen_tcp.close(socket)
    _ = File.rm(path)
    :ok
  end

  defp spawn_handler(%{task_supervisor: sup} = state, conn) do
    Task.Supervisor.start_child(sup, fn -> handle_connection(conn, state) end)
  end

  defp handle_connection(conn, state) do
    case :gen_tcp.recv(conn, 0, @recv_timeout_ms) do
      {:ok, line} ->
        response = handle_request(String.trim(line), state)
        :gen_tcp.send(conn, [Jason.encode!(response), "\n"])
        maybe_finalize(response)

      {:error, _reason} ->
        :ok
    end
  after
    :gen_tcp.close(conn)
  end

  defp handle_request(line, state) do
    case Jason.decode(line) do
      {:ok, %{"method" => "status"}} ->
        status_reply(state)

      {:ok, %{"method" => "shutdown"}} ->
        Trace.record(:agent_event, "daemon", %{event: "shutdown_requested"})
        %{status: "shutting_down"}

      {:ok, %{"method" => method}} ->
        %{status: "error", reason: "unknown method", method: method}

      _ ->
        %{status: "error", reason: "invalid request"}
    end
  end

  defp status_reply(state) do
    %{
      status: "ok",
      version: to_string(Application.spec(:fermix_core, :vsn) || "unknown"),
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at_ms,
      pid: System.pid()
    }
  end

  defp maybe_finalize(%{status: "shutting_down"}) do
    spawn(fn ->
      Process.sleep(150)
      :init.stop()
    end)
  end

  defp maybe_finalize(_), do: :ok

  defp default_socket_path do
    fermix_home = System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
    Path.join(fermix_home, "daemon.sock")
  end
end
