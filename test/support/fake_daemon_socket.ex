defmodule FermixTestSupport.FakeDaemonSocket do
  @moduledoc """
  A one-request stand-in for the daemon's control socket, for CLI verbs that
  reach a running daemon through `Fermix.CLI.Daemon.Client`.

  The CLI finds the socket at `FERMIX_HOME/daemon.sock`, so a test points
  `FERMIX_HOME` at `fermix_home!/0`: a directory directly under
  `System.tmp_dir!()`, not nested like `SafeRm.make_tmp_dir!/1`, because a unix
  socket address is capped at 104 bytes on macOS. `serve_once/2` answers
  exactly one v0 request, forwards the decoded frame to the test as
  `{:fake_daemon_request, request}`, and removes its socket; `serve_v1/3`
  answers a few v1 requests, one connection each, as a running engine does.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias FermixCore.SocketPath
  alias FermixTestSupport.SafeRm

  @doc """
  Points `FERMIX_HOME` at a fresh, SafeRm-marked directory under this run's
  `System.tmp_dir!()`. A `TMPDIR` too long for its `daemon.sock` fails the test
  at once, naming the fix. On exit the previous value comes back first, because
  SafeRm refuses to delete the live `FERMIX_HOME`, and then the directory goes.
  """
  @spec fermix_home!() :: String.t()
  def fermix_home! do
    name = "fermix-sock-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
    path = Path.join(System.tmp_dir!(), name)
    socket_fits!(Path.join(path, "daemon.sock"))
    File.mkdir!(path)
    SafeRm.mark!(path)
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", path)

    on_exit(fn ->
      restore_home(previous)
      SafeRm.rm_rf!(path)
    end)

    path
  end

  defp socket_fits!(socket_path) do
    case SocketPath.check(socket_path) do
      :ok ->
        :ok

      {:error, {:path_too_long, bytes, limit}} ->
        raise "the fake daemon socket #{socket_path} is #{bytes} bytes, over the " <>
                "#{limit}-byte limit this OS allows for a unix socket address; " <>
                "run the tests with a shorter TMPDIR"
    end
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)

  @doc """
  Listens on `home/daemon.sock`, answers the first request with `reply`, and
  returns once the listener is up. The caller awaits the task.
  """
  @spec serve_once(String.t(), map()) :: Task.t()
  def serve_once(home, reply) when is_binary(home) and is_map(reply) do
    parent = self()
    socket_path = Path.join(home, "daemon.sock")

    task =
      Task.async(fn ->
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [
            :binary,
            {:active, false},
            {:ifaddr, {:local, socket_path}},
            {:packet, 4},
            {:reuseaddr, true}
          ])

        send(parent, {:fake_daemon_ready, self()})
        {:ok, conn} = :gen_tcp.accept(listen_socket, 5_000)
        {:ok, frame} = :gen_tcp.recv(conn, 0, 5_000)
        send(parent, {:fake_daemon_request, Jason.decode!(frame)})
        :ok = :gen_tcp.send(conn, Jason.encode!(reply))
        :gen_tcp.close(conn)
        :gen_tcp.close(listen_socket)
        SafeRm.rm(socket_path)
      end)

    pid = task.pid

    receive do
      {:fake_daemon_ready, ^pid} -> task
    after
      5_000 -> raise "the fake daemon socket never started listening at #{socket_path}"
    end
  end

  @doc """
  Listens on `home/daemon.sock` as a running engine's management socket does
  for protocol v1: up to `count` connections, one request each, each answered
  with `answer.(method, params)` (`{:ok, result}` or `{:error, code, message,
  details}`) under the request's own id, and each forwarded to the test as
  `{:fake_daemon_v1, method, params}`. Returns once the listener is up; the
  socket goes once the last connection is answered, or with the caller.
  """
  @spec serve_v1(String.t(), pos_integer(), (String.t(), map() -> term())) :: Task.t()
  def serve_v1(home, count, answer)
      when is_binary(home) and is_integer(count) and count > 0 and is_function(answer, 2) do
    parent = self()
    socket_path = Path.join(home, "daemon.sock")

    task =
      Task.async(fn ->
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [
            :binary,
            {:active, false},
            {:ifaddr, {:local, socket_path}},
            {:packet, 4},
            {:reuseaddr, true}
          ])

        send(parent, {:fake_daemon_ready, self()})
        for _connection <- 1..count, do: answer_v1(listen_socket, parent, answer)
        :gen_tcp.close(listen_socket)
        SafeRm.rm(socket_path)
      end)

    pid = task.pid

    receive do
      {:fake_daemon_ready, ^pid} -> task
    after
      10_000 -> raise "the fake daemon socket never started listening at #{socket_path}"
    end
  end

  defp answer_v1(listen_socket, parent, answer) do
    {:ok, conn} = :gen_tcp.accept(listen_socket, 10_000)
    {:ok, frame} = :gen_tcp.recv(conn, 0, 10_000)
    %{"request_id" => id, "method" => method} = request = Jason.decode!(frame)
    params = Map.get(request, "params", %{})
    send(parent, {:fake_daemon_v1, method, params})

    reply =
      case answer.(method, params) do
        {:ok, result} ->
          %{"request_id" => id, "result" => result}

        {:error, code, message, details} ->
          %{
            "request_id" => id,
            "error" => %{"code" => code, "message" => message, "details" => details}
          }
      end

    :ok = :gen_tcp.send(conn, Jason.encode!(reply))
    :gen_tcp.close(conn)
  end
end
