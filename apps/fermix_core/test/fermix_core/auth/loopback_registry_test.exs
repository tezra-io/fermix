defmodule FermixCore.Auth.LoopbackRegistryTest do
  # The registry of open OAuth loopback listeners (M75 D17), each test with a
  # registry of its own, and the real flow recording its listener there.
  use ExUnit.Case, async: true

  alias FermixCore.Auth.LoopbackRegistry
  alias FermixCore.Auth.OAuthFlow
  alias FermixCore.Auth.OAuthProvider

  @expires ~U[2026-10-27 10:05:00Z]
  @desktop {:desktop, "desk-1"}

  setup do
    registry = start_supervised!({LoopbackRegistry, name: nil})
    %{registry: registry}
  end

  defp envelope(event), do: {:loopback, event}

  describe "the registry" do
    test "records a listener with its port, expiry and caller, and tells subscribers", %{
      registry: registry
    } do
      {:ok, []} = LoopbackRegistry.subscribe(&envelope/1, registry)
      {:ok, id} = LoopbackRegistry.open(53_682, @desktop, @expires, registry)

      assert_receive {:loopback, {:opened, entry}}
      assert %{id: ^id, port: 53_682, expires_at: @expires, owner: @desktop} = entry
      assert entry.flow == self()
      assert [%{id: ^id}] = LoopbackRegistry.list(registry)

      :ok = LoopbackRegistry.close(id, registry)
      assert_receive {:loopback, {:closed, %{id: ^id}}}
      assert LoopbackRegistry.list(registry) == []
    end

    test "a subscriber is answered the listeners open now", %{registry: registry} do
      {:ok, id} = LoopbackRegistry.open(40_001, nil, @expires, registry)
      assert {:ok, [%{id: ^id, owner: nil}]} = LoopbackRegistry.subscribe(&envelope/1, registry)
    end

    test "a flow that dies is closed for it", %{registry: registry} do
      {:ok, []} = LoopbackRegistry.subscribe(&envelope/1, registry)
      parent = self()

      flow =
        spawn(fn ->
          {:ok, id} = LoopbackRegistry.open(40_002, @desktop, @expires, registry)
          send(parent, {:opened_by_flow, id})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:opened_by_flow, id}
      send(flow, :stop)
      assert_receive {:loopback, {:closed, %{id: ^id}}}
    end

    test "a failure reaches the flow waiting on the listener", %{registry: registry} do
      {:ok, id} = LoopbackRegistry.open(40_003, @desktop, @expires, registry)
      failure = %{desktop: "Studio Mac", port: 40_003, reason: :port_in_use}

      assert :ok = LoopbackRegistry.fail(id, failure, registry)
      assert_receive {:loopback_forward_failed, ^id, ^failure}
      assert {:error, :unknown_loopback} = LoopbackRegistry.fail("lb-gone", failure, registry)
    end

    test "an unsubscribed process hears nothing more", %{registry: registry} do
      {:ok, []} = LoopbackRegistry.subscribe(&envelope/1, registry)
      :ok = LoopbackRegistry.unsubscribe(registry)
      {:ok, _id} = LoopbackRegistry.open(40_004, nil, @expires, registry)
      refute_receive {:loopback, _event}, 100
    end

    test "with no registry running nothing is recorded" do
      assert {:ok, nil} = LoopbackRegistry.open(40_005, nil, @expires, :no_such_registry)
      assert :ok = LoopbackRegistry.close(nil, :no_such_registry)
    end

    test "an owner is a desktop or nobody" do
      assert_raise ArgumentError, fn ->
        LoopbackRegistry.open(40_006, {:phone, "p-1"}, @expires, :no_such_registry)
      end
    end
  end

  describe "the flow's listener" do
    test "is recorded with the desktop that started it, for as long as it listens", %{
      registry: registry
    } do
      {:ok, []} = LoopbackRegistry.subscribe(&envelope/1, registry)

      assert {:ok, %{code: "c1"}} =
               await(registry, fn port, state ->
                 assert_receive {:loopback, {:opened, %{port: ^port, owner: @desktop}}}

                 "GET /callback?code=c1&state=#{state} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
               end)

      assert_receive {:loopback, {:closed, %{owner: @desktop}}}
      assert LoopbackRegistry.list(registry) == []
    end

    test "ends with the desktop's failure instead of waiting out its deadline", %{
      registry: registry
    } do
      {:ok, []} = LoopbackRegistry.subscribe(&envelope/1, registry)
      parent = self()

      opener = fn _url ->
        send(parent, :opened)
        :ok
      end

      task =
        Task.async(fn ->
          OAuthFlow.await_authorization(provider(),
            opener: opener,
            puts: fn _line -> :ok end,
            timeout_ms: 60_000,
            loopback_owner: @desktop,
            loopback_registry: registry
          )
        end)

      assert_receive {:loopback, {:opened, %{id: id, port: port}}}
      assert_receive :opened
      failure = %{desktop: "Studio Mac", port: port, reason: :port_in_use}
      :ok = LoopbackRegistry.fail(id, failure, registry)

      assert {:error, {:loopback_forward_failed, ^failure}} = Task.await(task, 10_000)
      assert_receive {:loopback, {:closed, %{id: ^id}}}
    end

    test "a local caller's listener names no owner", %{registry: registry} do
      {:ok, []} = LoopbackRegistry.subscribe(&envelope/1, registry)

      assert {:error, :callback_timeout} =
               OAuthFlow.await_authorization(provider(),
                 opener: fn _url -> :ok end,
                 puts: fn _line -> :ok end,
                 timeout_ms: 50,
                 loopback_registry: registry
               )

      assert_receive {:loopback, {:opened, %{owner: nil}}}
      assert_receive {:loopback, {:closed, %{owner: nil}}}
    end
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

  # One attempt whose browser sends `request.(port, state)` to the listener.
  defp await(registry, request) do
    parent = self()

    opener = fn url ->
      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      port = params["redirect_uri"] |> URI.parse() |> Map.fetch!(:port)
      send(parent, {:browse, port, params["state"]})
      :ok
    end

    task =
      Task.async(fn ->
        OAuthFlow.await_authorization(provider(),
          opener: opener,
          puts: fn _line -> :ok end,
          timeout_ms: 10_000,
          loopback_owner: @desktop,
          loopback_registry: registry
        )
      end)

    assert_receive {:browse, port, state}
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(conn, request.(port, state))
    {:ok, _response} = :gen_tcp.recv(conn, 0, 10_000)
    :gen_tcp.close(conn)
    Task.await(task, 10_000)
  end
end
