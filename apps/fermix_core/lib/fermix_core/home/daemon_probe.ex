defmodule FermixCore.Home.DaemonProbe do
  @moduledoc """
  The one answer to "is the engine that owns this home running?" for the verbs
  that must only run against a stopped home (`fermix home export`,
  `fermix home mark-moved`).

  It asks the home's control socket for `hello`, the probe `fermix status`
  uses (`Fermix.CLI.Daemon.Client.request_v1/3`): no listener (a missing
  socket, a refused connection) while no daemon holds the socket's lock
  (`Fermix.CLI.Daemon.Lock`) is a stopped home, an answer is a running one,
  and anything else is reported as a probe that could not tell, which callers
  refuse with what to do: a connect or a reply that timed out among them, and
  a connection turned away while the lock is held, since a daemon may be
  there on a machine too busy to answer.
  """

  alias Fermix.CLI.Daemon.Client

  @type result :: :ok | {:error, :daemon_running | {:daemon_probe_failed, term()}}

  @doc """
  `:ok` when no engine answers on `<home>/daemon.sock`. `opts[:hello]`, a
  0-arity function answering as `Client.request_v1/3` does, replaces the
  socket call in tests; `opts[:hello_timeout]` bounds the socket call's
  reply in milliseconds (the client's own by default), so a test on a busy
  runner waits as long as it names.
  """
  @spec stopped(Path.t(), keyword()) :: result()
  def stopped(home, opts \\ []) when is_binary(home) and home != "" and is_list(opts) do
    hello = Keyword.get(opts, :hello, fn -> hello(home, opts) end)

    case hello.() do
      {:error, :not_running} -> :ok
      {:ok, _hello} -> {:error, :daemon_running}
      {:error, reason} -> {:error, {:daemon_probe_failed, reason}}
    end
  end

  defp hello(home, opts) do
    socket = [socket_path: Path.join(home, "daemon.sock")]

    case Keyword.fetch(opts, :hello_timeout) do
      {:ok, ms} when is_integer(ms) and ms > 0 ->
        Client.request_v1("hello", %{}, [timeout: ms] ++ socket)

      :error ->
        Client.request_v1("hello", %{}, socket)
    end
  end
end
