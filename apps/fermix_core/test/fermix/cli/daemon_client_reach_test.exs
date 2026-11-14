defmodule Fermix.CLI.DaemonClientReachTest do
  # What the control socket's client answers when it cannot reach a daemon.
  # Only a missing socket or a refused connection is "not running": a connect
  # that times out may be a daemon on a starved machine, so Fermix could not
  # tell, and a verb that must not act on a live home refuses on it. Every
  # answer of the socket is injected (`:connect`); nothing waits on a real
  # stall.
  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Home.DaemonProbe

  @socket "/invented/home/daemon.sock"

  defp connecting(answer), do: fn @socket, _timeout -> answer end

  test "a missing socket or a refused connection is not running" do
    for reason <- [:enoent, :econnrefused] do
      assert Client.request_v1("hello", %{},
               socket_path: @socket,
               connect: connecting({:error, reason})
             ) ==
               {:error, :not_running},
             inspect(reason)

      assert Client.request("status", socket_path: @socket, connect: connecting({:error, reason})) ==
               {:error, :not_running},
             inspect(reason)
    end
  end

  test "a connect that times out could not tell, and never reads as not running" do
    timed_out = connecting({:error, :timeout})

    assert Client.request_v1("hello", %{}, socket_path: @socket, connect: timed_out) ==
             {:error, :timeout}

    assert Client.request("status", socket_path: @socket, connect: timed_out) ==
             {:error, :timeout}

    assert Client.describe_error(:timeout) =~ "could not tell whether it is running"
  end

  test "the home's probe reads a connect that timed out as could not tell" do
    hello = fn ->
      Client.request_v1("hello", %{},
        socket_path: @socket,
        connect: connecting({:error, :timeout})
      )
    end

    assert DaemonProbe.stopped("/invented/home", hello: hello) ==
             {:error, {:daemon_probe_failed, :timeout}}
  end
end
