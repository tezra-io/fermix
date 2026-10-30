defmodule FermixChannels.Desktop.LoopbackTest do
  @moduledoc """
  M75 D17, link F1: the desktop listens for a sign-in's reply only on a port
  nothing else on it listens on. A port another program holds (a wildcard
  listener included) is refused, never taken over; a port below 1024 or one
  of this engine's own is never taken; at most 8 loopbacks are open at once.
  Every refusal reaches the primary as `loopback_failed`.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Loopback
  alias FermixChannels.Desktop.LoopbackHttp

  @wait 10_000

  setup do
    test = self()
    name = :"desktop_loopback_test_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Loopback,
       name: name,
       own_ports: [4_030, 4_031],
       send: fn event, _payload ->
         send(test, {:to_primary, event})
         :ok
       end,
       schedule: fn _message, _delay -> make_ref() end}
    )

    %{loopback: name}
  end

  test "a port another program listens on is refused, a wildcard listener included", ctx do
    {:ok, other} = :gen_tcp.listen(0, [:binary, active: false, ip: {0, 0, 0, 0}])
    {:ok, port} = :inet.port(other)

    open(ctx, "lb-1", [port])

    assert_receive {:to_primary,
                    %{
                      "t" => "loopback_failed",
                      "loopback_id" => "lb-1",
                      "port" => ^port,
                      "reason" => "port_in_use"
                    }}

    assert Loopback.listening(ctx.loopback) == %{"lb-1" => []}

    # The other program still has every connection to its port.
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    assert {:ok, _server_side} = :gen_tcp.accept(other, 1_000)
    :ok = :gen_tcp.close(client)
    :ok = :gen_tcp.close(other)
  end

  test "a port below 1024 or one of this engine's own is never taken", ctx do
    open(ctx, "lb-2", [80, 4_031])

    for port <- [80, 4_031] do
      assert_receive {:to_primary,
                      %{"t" => "loopback_failed", "port" => ^port, "reason" => "not_permitted"}}
    end

    assert Loopback.listening(ctx.loopback) == %{"lb-2" => []}
  end

  # A sign-in served here closes its connection from this side once it has
  # answered, which leaves the port to that closed connection for about a
  # minute. Linux binds over it only when the connection carried
  # `SO_REUSEADDR` too, which it takes from the listener that accepted it;
  # macOS asks only the socket binding. So the listener carries the option
  # (checked on every host), and a second sign-in on the port within the
  # minute is listened for again (which only Linux refuses without it).
  test "a free port is taken, and one a previous sign-in was served on is taken again", ctx do
    port = free_port()
    open(ctx, "lb-3", [port])
    assert Loopback.listening(ctx.loopback) == %{"lb-3" => [port]}
    assert {:ok, [reuseaddr: true]} = :inet.getopts(listener(ctx, "lb-3", port), [:reuseaddr])

    request = %{method: "GET", target: "/callback?code=c1", headers: [], body: ""}
    browser = Task.async(fn -> LoopbackHttp.replay(port, request, @wait) end)
    assert_receive {:to_primary, %{"t" => "loopback_request", "request_id" => request_id}}, @wait
    answer(ctx, request_id, "signed in")
    assert {:ok, %{status: 200, body: "signed in"}} = Task.await(browser, @wait)

    close(ctx, "lb-3")
    assert Loopback.listening(ctx.loopback) == %{}

    open(ctx, "lb-4", [port])
    assert Loopback.listening(ctx.loopback) == %{"lb-4" => [port]}
    refute_received {:to_primary, %{"t" => "loopback_failed"}}
  end

  test "at most 8 loopbacks are open at once", ctx do
    ports =
      for _n <- 1..9 do
        {:ok, probe} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(probe)
        :ok = :gen_tcp.close(probe)
        port
      end

    for {port, n} <- Enum.with_index(ports, 1), do: open(ctx, "lb-#{n}", [port])

    listening = Loopback.listening(ctx.loopback)
    assert map_size(listening) == 8
    refute Map.has_key?(listening, "lb-9")
    ninth = List.last(ports)

    assert_receive {:to_primary,
                    %{
                      "t" => "loopback_failed",
                      "loopback_id" => "lb-9",
                      "port" => ^ninth,
                      "reason" => "failed"
                    }}
  end

  defp free_port do
    {:ok, probe} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(probe)
    :ok = :gen_tcp.close(probe)
    port
  end

  # The loopback's own listening socket for `port`.
  defp listener(ctx, id, port) do
    %{loopbacks: %{^id => %{listeners: %{^port => socket}}}} = :sys.get_state(ctx.loopback)
    socket
  end

  defp answer(ctx, request_id, body) do
    fields = %{
      "request_id" => request_id,
      "status" => 200,
      "headers" => [["Content-Type", "text/plain; charset=utf-8"]]
    }

    :ok = Loopback.handle(ctx.loopback, "loopback_response", fields, body)
  end

  defp close(ctx, id),
    do: :ok = Loopback.handle(ctx.loopback, "loopback_close", %{"loopback_id" => id}, <<>>)

  defp open(ctx, id, ports) do
    :ok =
      Loopback.handle(
        ctx.loopback,
        "loopback_open",
        %{
          "loopback_id" => id,
          "ports" => ports,
          "expires_in_s" => 900
        },
        <<>>
      )
  end
end
