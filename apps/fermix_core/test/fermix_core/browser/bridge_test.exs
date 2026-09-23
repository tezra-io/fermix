defmodule FermixCore.Browser.BridgeTest do
  # The bridge from the extension's side: a real listener on a throwaway socket,
  # a real `Peer` per connection, a real `Grants` table, and a real
  # `ExtensionTransport` on the far side of it.
  #
  # async: false — each case binds a Unix socket and starts named processes.
  use ExUnit.Case, async: false

  import Bitwise

  alias FermixCore.Browser.Bridge.Endpoint
  alias FermixCore.Browser.Bridge.Grants
  alias FermixCore.Browser.Bridge.Supervisor, as: BridgeSupervisor
  alias FermixCore.Browser.CDP.ExtensionTransport
  alias FermixCore.Browser.Error
  alias FermixTestSupport.SafeRm

  @tab_id 77
  @connect_timeout 1_000

  setup do
    # Short on purpose: a Unix socket address is capped around 104 bytes, which a
    # nested tmp directory blows straight through (`:einval` on bind).
    socket_path =
      Path.join(System.tmp_dir!(), "fermix-bridge-#{System.unique_integer([:positive])}.sock")

    on_exit(fn -> SafeRm.rm(socket_path) end)
    {:ok, socket_path: socket_path}
  end

  defp start_bridge(ctx, opts \\ []) do
    opts = Keyword.merge([socket_path: ctx.socket_path, name: nil], opts)
    start_supervised!({BridgeSupervisor, opts}, id: :bridge)
    Process.whereis(Grants)
  end

  defp connect!(ctx) do
    {:ok, socket} =
      :gen_tcp.connect(
        {:local, to_charlist(ctx.socket_path)},
        0,
        [:binary, {:active, false}, {:packet, 4}, {:packet_size, 33_554_432}],
        @connect_timeout
      )

    socket
  end

  defp send_frame(socket, frame), do: :ok = :gen_tcp.send(socket, Jason.encode!(frame))

  defp recv_frame(socket, timeout \\ @connect_timeout) do
    {:ok, frame} = :gen_tcp.recv(socket, 0, timeout)
    Jason.decode!(frame)
  end

  defp hello!(ctx) do
    socket = connect!(ctx)
    send_frame(socket, %{type: "hello", protocol: 1, browser: "chrome"})
    assert %{"type" => "hello_ack", "protocol" => 1} = recv_frame(socket)
    socket
  end

  # ── the socket itself ──────────────────────────────────────────────────────

  test "binds the socket at 0600 and removes it on shutdown", ctx do
    start_bridge(ctx)

    assert File.exists?(ctx.socket_path)
    assert (File.stat!(ctx.socket_path).mode &&& 0o777) == 0o600

    stop_supervised!(:bridge)
    refute File.exists?(ctx.socket_path)
  end

  test "a stale socket file from a crashed daemon is unlinked", ctx do
    File.write!(ctx.socket_path, "")
    start_bridge(ctx)

    assert File.exists?(ctx.socket_path)
    # The proof the listener owns the new socket rather than the leftover file:
    # a client gets through the handshake on it.
    assert is_port(hello!(ctx))
  end

  test "a live socket is not stolen, and the rest of the daemon lives on", ctx do
    start_bridge(ctx)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ignore = Endpoint.init(socket_path: ctx.socket_path, name: nil)
      end)

    assert log =~ "another daemon is already listening"
    assert File.exists?(ctx.socket_path)
  end

  # ── the handshake ──────────────────────────────────────────────────────────

  test "an unknown protocol is refused, never guessed at", ctx do
    start_bridge(ctx)
    socket = connect!(ctx)

    send_frame(socket, %{type: "hello", protocol: 99})
    assert %{"type" => "refused", "reason" => "unsupported_protocol"} = recv_frame(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, @connect_timeout)
  end

  test "a frame before the handshake is refused", ctx do
    start_bridge(ctx)
    socket = connect!(ctx)

    send_frame(socket, %{type: "grant", tab_id: @tab_id})
    assert %{"type" => "refused", "reason" => "hello_required"} = recv_frame(socket)
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, @connect_timeout)
  end

  test "an unknown message type is named, and the session carries on", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)

    send_frame(socket, %{type: "evaluate_everything"})
    assert %{"type" => "refused", "reason" => "unknown_message"} = recv_frame(socket)

    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, grant} = eventually_claimed(grants)
    assert grant.tab_id == @tab_id
  end

  test "a frame that is not a JSON object is refused", ctx do
    start_bridge(ctx)
    socket = connect!(ctx)

    :ok = :gen_tcp.send(socket, "not json at all")
    assert %{"type" => "refused", "reason" => "malformed_frame"} = recv_frame(socket)
  end

  # ── grants ─────────────────────────────────────────────────────────────────

  test "a granted tab is claimable once, and the claim survives re-asking", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)

    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, grant} = eventually_claimed(grants)
    assert grant.url == "https://example.com"

    assert {:ok, ^grant} = Grants.claim(grants, "owner-one")
    assert {:error, :no_grant} = Grants.claim(grants, "owner-two")
  end

  test "a revoke drops the grant", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)

    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    send_frame(socket, %{type: "revoke", tab_id: @tab_id, reason: "tab_closed"})
    assert eventually_gone(grants)
  end

  test "an extension that disconnects takes its grants with it", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)

    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    :ok = :gen_tcp.close(socket)
    assert eventually_gone(grants)
  end

  # ── commands ───────────────────────────────────────────────────────────────

  test "a command travels to the extension and its result comes back", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)
    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    {:ok, transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: claim!(grants)
      )

    caller =
      Task.async(fn ->
        ExtensionTransport.command(
          transport,
          "Page.navigate",
          %{url: "https://a"},
          nil,
          2_000,
          100
        )
      end)

    assert %{"type" => "cdp", "id" => id, "tab_id" => @tab_id, "method" => "Page.navigate"} =
             frame = recv_frame(socket)

    assert frame["params"] == %{"url" => "https://a"}

    send_frame(socket, %{type: "cdp_result", id: id, result: %{"frameId" => "F1"}})
    assert {:ok, %{"frameId" => "F1"}} = Task.await(caller, 3_000)
  end

  test "an event for the granted tab reaches the transport's owner", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)
    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    {:ok, _transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: claim!(grants)
      )

    send_frame(socket, %{
      type: "event",
      tab_id: @tab_id,
      method: "Page.javascriptDialogOpening",
      params: %{"message" => "hi"}
    })

    assert_receive {:cdp_event, "Page.javascriptDialogOpening", event}, 1_000
    assert event["params"]["message"] == "hi"
  end

  test "a reply for an id nobody is waiting on is dropped, not matched by position", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)
    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    {:ok, transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: claim!(grants)
      )

    # A result for an id that was never issued: the peer must survive it and
    # must not hand it to the next command.
    send_frame(socket, %{type: "cdp_result", id: 987_654, result: %{"stolen" => true}})

    caller =
      Task.async(fn ->
        ExtensionTransport.command(transport, "Runtime.evaluate", %{}, nil, 2_000, 100)
      end)

    assert %{"type" => "cdp", "id" => id} = recv_frame(socket)
    send_frame(socket, %{type: "cdp_result", id: id, result: %{"mine" => true}})
    assert {:ok, %{"mine" => true}} = Task.await(caller, 3_000)
  end

  test "a cdp_error comes back as a CDP error, not as a result", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)
    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    {:ok, transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: claim!(grants)
      )

    caller =
      Task.async(fn ->
        ExtensionTransport.command(transport, "Page.navigate", %{}, nil, 2_000, 100)
      end)

    assert %{"id" => id} = recv_frame(socket)
    send_frame(socket, %{type: "cdp_error", id: id, message: "Cannot navigate to invalid URL"})

    assert {:error, %Error{code: "cdp_error", message: "Cannot navigate to invalid URL"}} =
             Task.await(caller, 3_000)
  end

  test "the transport releases the tab when it goes", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)
    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    {:ok, transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: claim!(grants)
      )

    ExtensionTransport.close(transport)
    assert %{"type" => "release", "tab_id" => @tab_id} = recv_frame(socket)
  end

  # ── the status probe `fermix browser bridge status` makes ──────────────────

  test "status reports connected extensions and granted tabs", ctx do
    grants = start_bridge(ctx)
    extension = hello!(ctx)

    send_frame(extension, %{type: "grant", tab_id: @tab_id, url: "https://e.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    probe = connect!(ctx)
    send_frame(probe, %{type: "status"})

    assert %{"type" => "status_ok", "extensions" => 1, "granted_tabs" => 1} = recv_frame(probe)
    assert {:error, :closed} = :gen_tcp.recv(probe, 0, @connect_timeout)
  end

  # ── the method allowlist, before anything is transmitted ───────────────────

  @browser_wide [
    "Browser.setDownloadBehavior",
    "Browser.cancelDownload",
    "Target.getTargets",
    "Target.createTarget",
    "Target.closeTarget",
    "Target.activateTarget",
    "Target.attachToTarget",
    "Network.getAllCookies",
    "Network.clearBrowserCookies",
    "Storage.clearDataForOrigin",
    "Security.disable"
  ]

  test "a browser-wide method is refused before a byte is sent", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)
    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://e.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    {:ok, transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: claim!(grants)
      )

    for method <- @browser_wide do
      assert {:error, %Error{code: "unsupported_in_attached_tab"}} =
               ExtensionTransport.command(transport, method, %{}, nil, 2_000, 100)
    end

    # Nothing was transmitted: the extension has no frame to read.
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 200)
  end

  test "a command over the outbound ceiling is refused before transmission", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)
    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://e.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    {:ok, transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: claim!(grants)
      )

    oversize = %{"data" => String.duplicate("x", 1_100_000)}

    assert {:error, %Error{code: "command_too_large"} = error} =
             ExtensionTransport.command(transport, "Runtime.evaluate", oversize, nil, 2_000, 100)

    assert error.message =~ "managed browser profile"
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 200)
  end

  test "an unanswered command times out with the precise CDP error", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)
    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://e.com", title: "P"})
    assert {:ok, _grant} = eventually_claimed(grants)

    {:ok, transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: claim!(grants)
      )

    assert {:error, %Error{code: "cdp_timeout"}} =
             ExtensionTransport.command(transport, "Page.navigate", %{}, nil, 100, 50)

    assert %{"type" => "cdp"} = recv_frame(socket)
  end

  # ── two browsers, one tab id ───────────────────────────────────────────────

  # Tab ids are a browser's own counter, so two connected extensions hand out the
  # same small integers. Keyed on the id alone, the second browser's grant
  # replaced the first's and its events were delivered to the first's transport.
  test "a second extension cannot take over the first's tab id", ctx do
    grants = start_bridge(ctx)
    first = hello!(ctx)
    second = hello!(ctx)

    send_frame(first, %{
      type: "grant",
      tab_id: @tab_id,
      url: "https://mine.example",
      title: "Mine"
    })

    assert {:ok, mine} = eventually_claimed(grants)
    assert mine.url == "https://mine.example"

    send_frame(second, %{
      type: "grant",
      tab_id: @tab_id,
      url: "https://theirs.example",
      title: "Theirs"
    })

    # Both rows exist; the first one is still the first browser's.
    assert eventually_tabs(grants, 2)
    assert {:ok, ^mine} = Grants.claim(grants, "owner-one")
  end

  test "an event from one extension never reaches the other's transport", ctx do
    grants = start_bridge(ctx)
    mine = hello!(ctx)
    theirs = hello!(ctx)

    send_frame(mine, %{type: "grant", tab_id: @tab_id, url: "https://mine.example", title: "M"})
    assert {:ok, grant} = eventually_claimed(grants)

    {:ok, _transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: grant
      )

    send_frame(theirs, %{
      type: "grant",
      tab_id: @tab_id,
      url: "https://theirs.example",
      title: "T"
    })

    assert eventually_tabs(grants, 2)

    send_frame(theirs, %{
      type: "event",
      tab_id: @tab_id,
      method: "Page.javascriptDialogOpening",
      params: %{"message" => "not yours"}
    })

    refute_receive {:cdp_event, _method, _event}, 300
  end

  test "a revoke from one extension does not drop the other's grant", ctx do
    grants = start_bridge(ctx)
    mine = hello!(ctx)
    theirs = hello!(ctx)

    send_frame(mine, %{type: "grant", tab_id: @tab_id, url: "https://mine.example", title: "M"})
    assert {:ok, _grant} = eventually_claimed(grants)

    send_frame(theirs, %{
      type: "grant",
      tab_id: @tab_id,
      url: "https://theirs.example",
      title: "T"
    })

    assert eventually_tabs(grants, 2)

    send_frame(theirs, %{type: "revoke", tab_id: @tab_id, reason: "tab_closed"})
    assert eventually_tabs(grants, 1)
    assert {:ok, %{url: "https://mine.example"}} = Grants.claim(grants, "owner-one")
  end

  # ── a release is a detach ──────────────────────────────────────────────────

  test "a released tab leaves no row behind for the next claim to bind", ctx do
    grants = start_bridge(ctx)
    socket = hello!(ctx)
    send_frame(socket, %{type: "grant", tab_id: @tab_id, url: "https://example.com", title: "P"})
    assert {:ok, grant} = eventually_claimed(grants)

    {:ok, transport} =
      ExtensionTransport.start_link("bridge:#{@tab_id}",
        owner: self(),
        keepalive_ms: 30_000,
        grants: grants,
        grant: grant
      )

    ExtensionTransport.close(transport)
    assert %{"type" => "release", "tab_id" => @tab_id} = recv_frame(socket)

    assert eventually_tabs(grants, 0)
    assert {:error, :no_grant} = Grants.claim(grants, "owner-two")
  end

  # ── a slot is not held by a client that never speaks ───────────────────────

  test "a connection that never says hello is refused and its slot released", ctx do
    start_bridge(ctx, max_connections: 1)
    silent = connect!(ctx)

    # The deadline is ten seconds, far longer than a test should wait, so the
    # message itself is delivered: what is under test is that the handler exists
    # and frees the slot, not the wall clock.
    send(eventually_peer(), :hello_deadline)

    assert %{"type" => "refused", "reason" => "hello_timeout"} = recv_frame(silent)
    assert {:error, :closed} = :gen_tcp.recv(silent, 0, @connect_timeout)
    assert eventually_free_slot(ctx)
  end

  # The listener accepts on a poll, so the Peer exists a beat after connect/1.
  defp eventually_peer(attempts \\ 40) do
    BridgeSupervisor.peer_supervisor()
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn {_id, pid, _type, _mods} -> is_pid(pid) && pid end)
    |> case do
      nil when attempts > 0 ->
        Process.sleep(25)
        eventually_peer(attempts - 1)

      pid ->
        pid
    end
  end

  defp eventually_free_slot(ctx, attempts \\ 40) do
    %{active: active} = DynamicSupervisor.count_children(BridgeSupervisor.peer_supervisor())

    cond do
      active == 0 -> true
      attempts > 0 -> Process.sleep(25) && eventually_free_slot(ctx, attempts - 1)
      true -> false
    end
  end

  defp claim!(grants) do
    {:ok, grant} = eventually_claimed(grants)
    grant
  end

  defp eventually_tabs(grants, count, attempts \\ 40) do
    case Grants.summary(grants) do
      %{tabs: ^count} ->
        true

      _other when attempts > 0 ->
        Process.sleep(25)
        eventually_tabs(grants, count, attempts - 1)

      _other ->
        false
    end
  end

  # Grants are written by a message from the socket, so the claim is only a fact
  # once the peer has processed it: poll rather than sleep for it.
  defp eventually_claimed(grants, attempts \\ 40) do
    case Grants.claim(grants, "owner-one") do
      {:ok, grant} ->
        {:ok, grant}

      {:error, :no_grant} when attempts > 0 ->
        Process.sleep(25)
        eventually_claimed(grants, attempts - 1)

      other ->
        other
    end
  end

  defp eventually_gone(grants, attempts \\ 40) do
    case Grants.claim(grants, "owner-later") do
      {:error, :no_grant} ->
        true

      {:ok, _grant} when attempts > 0 ->
        Process.sleep(25)
        eventually_gone(grants, attempts - 1)

      {:ok, _grant} ->
        false
    end
  end
end
