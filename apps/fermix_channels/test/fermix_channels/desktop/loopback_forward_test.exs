defmodule FermixChannels.Desktop.LoopbackForwardTest do
  # The sign-in loopback forward end to end in one VM (M75 D17): a real
  # `OAuthFlow` listener on the "primary", the primary's `loopback` family,
  # and the "desktop"'s listener, wired together in place of the rail. Both
  # ends run on one machine here, where the primary's listener already has
  # its port, so the desktop listens on another port (`:bind_port`) and the
  # browser names the primary's in `Host`, as it does on a desktop that has
  # the port to itself.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Loopback
  alias FermixChannels.Desktop.LoopbackForward
  alias FermixChannels.Test.DesktopFamilyHost
  alias FermixCore.Auth.LoopbackRegistry
  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider

  @desktop "desk-1"
  @owner {:desktop, @desktop}
  @wait 10_000

  setup do
    test = self()
    registry = start_supervised!({LoopbackRegistry, name: nil})
    name = :"loopback_#{System.unique_integer([:positive])}"

    # The primary sends the desktop an event: it reaches the desktop's
    # listener (the relay's part) when the test started one, and the test
    # hears of it.
    to_desktop = fn _device, %{"t" => type} = event, payload, _opts ->
      _served = Loopback.handle(name, type, Map.delete(event, "t"), payload)
      send(test, {:to_desktop, type, event, payload})
      :ok
    end

    host =
      DesktopFamilyHost.start(
        LoopbackForward,
        %{device_id: @desktop, session: test},
        options: [loopback_registry: registry, device_name: "Studio Mac", send: to_desktop]
      )

    %{me: test, registry: registry, name: name, host: host}
  end

  # The desktop sends the primary an event: the primary's family has it.
  defp start_desktop(ctx, opts) do
    to_primary = fn %{"t" => type} = event, payload ->
      send(ctx.me, {:to_primary, type, event})
      DesktopFamilyHost.event(ctx.host, type, Map.delete(event, "t"), payload)
    end

    start_supervised!(
      {Loopback,
       Keyword.merge(
         [
           name: ctx.name,
           send: to_primary,
           schedule: fn message, delay -> send(ctx.me, {:scheduled, message, delay}) end
         ],
         opts
       )}
    )
  end

  # The port the desktop listens on in place of the primary's, told to the test.
  defp free_port_for(test) do
    fn port ->
      {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
      {:ok, free} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)
      send(test, {:bound, port, free})
      free
    end
  end

  # The desktop's own port for `port`, once it listens there. `{:bound, ...}`
  # comes from inside the desktop's `loopback_open`, before it listens; its
  # answer to `listening/1` comes after it has served that event.
  defp desktop_port(ctx, port) do
    assert_receive {:bound, ^port, desktop_port}
    assert [{_id, [^port]}] = Map.to_list(Loopback.listening(ctx.name))
    desktop_port
  end

  defp provider do
    %OAuthProvider{
      id: :mcp,
      authorize_url: "https://auth.example/authorize",
      token_url: "https://auth.example/token",
      client_id: "client",
      redirect_host: "127.0.0.1",
      redirect_port: 0,
      redirect_path: "/callback",
      scopes: ["read"],
      hardened_callback?: true
    }
  end

  defp sign_in(ctx, timeout_ms \\ @wait) do
    test = ctx.me

    Task.async(fn ->
      OAuthFlow.await_authorization(provider(),
        opener: fn url -> send(test, {:authorize, url}) && :ok end,
        puts: fn _line -> :ok end,
        timeout_ms: timeout_ms,
        loopback_owner: @owner,
        loopback_registry: ctx.registry
      )
    end)
  end

  defp authorize_params do
    assert_receive {:authorize, url}
    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    port = params["redirect_uri"] |> URI.parse() |> Map.fetch!(:port)
    {port, params["state"]}
  end

  # The desktop's browser: one request to `port`, naming `host_port` in Host,
  # read until the desktop closes the connection.
  defp browse(port, host_port, target) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request =
      "GET #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{host_port}\r\nAccept: text/html\r\n" <>
        "Connection: keep-alive\r\n\r\n"

    :ok = :gen_tcp.send(conn, request)
    response = read_all(conn, "")
    :gen_tcp.close(conn)
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status_line | _headers] = String.split(head, "\r\n")
    [_version, status | _reason] = String.split(status_line, " ")
    {String.to_integer(status), head, body}
  end

  defp read_all(conn, acc) do
    case :gen_tcp.recv(conn, 0, @wait) do
      {:ok, bytes} -> read_all(conn, acc <> bytes)
      {:error, :closed} -> acc
    end
  end

  test "the provider's redirect on the desktop reaches the primary's listener, and its page comes back",
       ctx do
    start_desktop(ctx, bind_port: free_port_for(ctx.me))
    task = sign_in(ctx)
    {port, state} = authorize_params()

    assert_receive {:to_desktop, "loopback_open", %{"ports" => [^port], "expires_in_s" => s}, _}
    assert s > 0 and s <= 900
    desktop_port = desktop_port(ctx, port)

    {status, head, body} = browse(desktop_port, port, "/callback?code=c1&state=#{state}")
    assert status == 200
    assert head =~ "text/html"
    assert head =~ "Connection: close"
    assert body =~ "<html"

    assert {:ok, %{code: "c1"}} = Task.await(task, @wait)

    # The sign-in ended, so the desktop stops listening.
    assert_receive {:to_desktop, "loopback_close", _event, _payload}
    assert Loopback.listening(ctx.name) == %{}
  end

  test "a port the desktop cannot open ends the sign-in with that sentence's facts", ctx do
    {:ok, taken} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, taken_port} = :inet.port(taken)
    on_exit(fn -> :gen_tcp.close(taken) end)

    start_desktop(ctx, bind_port: fn _port -> taken_port end)
    task = sign_in(ctx)
    {port, _state} = authorize_params()

    assert_receive {:to_primary, "loopback_failed", %{"port" => ^port, "reason" => "port_in_use"}}

    assert {:error,
            {:loopback_forward_failed,
             %{desktop: "Studio Mac", port: ^port, reason: :port_in_use}}} =
             Task.await(task, @wait)
  end

  test "the desktop stops listening when the time the primary gave runs out", ctx do
    start_desktop(ctx, bind_port: free_port_for(ctx.me))
    task = sign_in(ctx)
    {port, _state} = authorize_params()
    assert_receive {:bound, ^port, desktop_port}
    assert_receive {:scheduled, {:expire, _id, _token} = expire, delay}
    assert delay > 0 and delay <= 900_000

    assert [{_id, [^port]}] = Map.to_list(Loopback.listening(ctx.name))
    send(GenServer.whereis(ctx.name), expire)
    assert Loopback.listening(ctx.name) == %{}

    assert {:error, :econnrefused} =
             :gen_tcp.connect(~c"127.0.0.1", desktop_port, [:binary, active: false])

    Task.shutdown(task, :brutal_kill)
  end

  test "the desktop forwards at most 8 requests of one loopback", ctx do
    start_desktop(ctx, bind_port: free_port_for(ctx.me))
    task = sign_in(ctx)
    {port, _state} = authorize_params()
    desktop_port = desktop_port(ctx, port)

    # Not the callback, so the listener answers each and keeps waiting.
    for _n <- 1..8 do
      assert {404, _head, _body} = browse(desktop_port, port, "/favicon.ico")
      assert_receive {:to_primary, "loopback_request", _event}
    end

    assert {429, _head, _body} = browse(desktop_port, port, "/favicon.ico")
    refute_received {:to_primary, "loopback_request", _event}

    Task.shutdown(task, :brutal_kill)
  end

  test "the primary answers a ninth request itself, and one for an ended loopback", ctx do
    task = sign_in(ctx)
    {port, _state} = authorize_params()
    assert_receive {:to_desktop, "loopback_open", %{"loopback_id" => id}, _payload}

    request = fn request_id ->
      DesktopFamilyHost.event(ctx.host, "loopback_request", %{
        "loopback_id" => id,
        "request_id" => request_id,
        "method" => "GET",
        "target" => "/favicon.ico",
        "headers" => [["Host", "127.0.0.1:#{port}"]]
      })
    end

    for n <- 1..8 do
      :ok = request.("rq-#{n}")
      assert_receive {:to_desktop, "loopback_response", %{"status" => 404}, _body}, @wait
    end

    :ok = request.("rq-9")

    assert_receive {:to_desktop, "loopback_response", %{"request_id" => "rq-9", "status" => 429},
                    _}

    Task.shutdown(task, :brutal_kill)
    assert_receive {:to_desktop, "loopback_close", %{"loopback_id" => ^id}, _payload}

    :ok = request.("rq-10")

    assert_receive {:to_desktop, "loopback_response", %{"request_id" => "rq-10", "status" => 410},
                    _}
  end

  test "another caller's sign-in is not opened on this desktop", ctx do
    {:ok, _id} =
      LoopbackRegistry.open(41_234, {:desktop, "desk-2"}, ~U[2099-01-01 00:00:00Z], ctx.registry)

    {:ok, _id} = LoopbackRegistry.open(41_235, nil, ~U[2099-01-01 00:00:00Z], ctx.registry)
    refute_receive {:to_desktop, "loopback_open", _event, _payload}, 100
  end

  test "the wire's reasons for a port it cannot open are the family's" do
    assert Enum.sort(LoopbackForward.failure_reasons()) == [
             "failed",
             "not_permitted",
             "port_in_use"
           ]
  end
end
