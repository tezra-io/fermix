defmodule Fermix.CLI.Doctor.MobileCheckTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Doctor.Checks
  alias FermixTestSupport.SafeRm

  # A P-256 key with SHA-256 signatures, which any TLS 1.3 client accepts.
  @test_key [key: {:namedCurve, :secp256r1}, digest: :sha256]

  setup do
    original = Application.get_env(:fermix_channels, :mobile)
    mobile_dir = SafeRm.make_tmp_dir!("doctor-mobile")

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_channels, :mobile)
        value -> Application.put_env(:fermix_channels, :mobile, value)
      end

      SafeRm.rm_rf!(mobile_dir)
    end)

    %{mobile_dir: mobile_dir}
  end

  test "disabled mobile is healthy and needs no identity", %{mobile_dir: mobile_dir} do
    Application.put_env(:fermix_channels, :mobile, enabled: false)

    result = Checks.mobile(mobile_dir: mobile_dir, client: fn _ -> flunk("no RPC") end)

    assert result == %{name: "mobile companion", status: :ok, detail: "disabled"}
  end

  # The channel ships on, so an install with no phone is the normal state, not
  # a problem, and the row names no CLI verb: on an app-managed Mac pairing
  # belongs to the app.
  test "enabled but never paired passes and names no CLI verb", %{mobile_dir: mobile_dir} do
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    result = Checks.mobile(mobile_dir: mobile_dir, client: fn _ -> flunk("no RPC") end)

    assert result == %{name: "mobile companion", status: :ok, detail: "on, no phone paired yet"}
  end

  test "a half-created identity is refused rather than read as unpaired", %{
    mobile_dir: mobile_dir
  } do
    write_identity_files(mobile_dir)
    SafeRm.rm!(Path.join(mobile_dir, "tls.key"))
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    result = Checks.mobile(mobile_dir: mobile_dir, client: fn _ -> flunk("no RPC") end)

    assert result.status == :fail
    assert result.detail =~ "tls.key"
  end

  test "enabled mobile refuses identity files that are not 0600", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)
    File.chmod!(Path.join(mobile_dir, "gateway_key"), 0o644)
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    result = Checks.mobile(mobile_dir: mobile_dir, client: fn _ -> flunk("no RPC") end)

    assert result.status == :fail
    assert result.detail =~ "0600"
    assert result.detail =~ "gateway_key"
  end

  test "healthy daemon status reports listener, discovery, tailnet, APNs and count", %{
    mobile_dir: mobile_dir
  } do
    write_identity_files(mobile_dir)

    Application.put_env(:fermix_channels, :mobile,
      enabled: true,
      advertise_mdns: true,
      push: [enabled: true]
    )

    client =
      live_client(%{
        "listener" => %{
          "status" => "ready",
          "candidates" => ["wss://lan:4031/ws", "wss://tailnet:4031/ws"]
        },
        "mdns" => "advertising",
        "tailnet" => %{"detected" => true, "candidates" => ["tailnet"]},
        "apns" => %{"enabled" => true, "credentials" => "ready", "delivery" => "ready"},
        "paired_devices" => 2
      })

    health_probe = fn "https://lan:4031/healthz", 750 -> :ok end
    result = Checks.mobile(mobile_dir: mobile_dir, client: client, health_probe: health_probe)

    assert result.status == :ok
    assert result.detail =~ "listener reachable at wss://lan:4031/ws (2 candidates)"
    assert result.detail =~ "mDNS advertising"
    assert result.detail =~ "tailnet detected"
    assert result.detail =~ "APNs ready"
    assert result.detail =~ "2 paired devices"
  end

  test "enabled mobile requires one bounded TLS health candidate", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)
    Application.put_env(:fermix_channels, :mobile, enabled: true)
    test_pid = self()

    candidates =
      Enum.map(1..12, fn index -> "wss://candidate-#{index}.example:#{4_000 + index}/ws" end)

    client =
      live_client(%{
        "listener" => %{"status" => "ready", "candidates" => candidates},
        "mdns" => "advertising",
        "tailnet" => %{"detected" => false, "candidates" => []},
        "apns" => %{"enabled" => false, "credentials" => "missing"},
        "paired_devices" => 1
      })

    health_probe = fn url, timeout_ms ->
      send(test_pid, {:health_probe, url, timeout_ms})
      {:error, :econnrefused}
    end

    result = Checks.mobile(mobile_dir: mobile_dir, client: client, health_probe: health_probe)

    assert result.status == :fail
    assert result.detail =~ "no advertised candidate passed TLS /healthz"
    assert_receive {:health_probe, "https://candidate-1.example:4001/healthz", 750}
    assert_receive {:health_probe, "https://candidate-8.example:4008/healthz", 750}
    refute_receive {:health_probe, "https://candidate-9.example:4009/healthz", 750}
  end

  # D1(a): /healthz answers the protocol version the daemon serves, so a bump
  # of that version must not make a working listener read as unreachable. What
  # proves a Fermix listener is the name and a version, whichever it is.
  test "the TLS probe takes any protocol version /healthz names", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    newer = start_health_server(~s({"fermix":"mobile","v":2}))
    assert mobile_probe_detail(mobile_dir, newer) =~ "listener reachable at wss://127.0.0.1:"

    versionless = start_health_server(~s({"fermix":"mobile","v":0}))

    assert mobile_probe_detail(mobile_dir, versionless) =~
             "no advertised candidate passed TLS /healthz"
  end

  test "listener with no advertised candidates fails without probing", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    client =
      live_client(%{
        "listener" => %{"status" => "ready", "candidates" => []},
        "mdns" => "advertising",
        "tailnet" => %{"detected" => false, "candidates" => []},
        "apns" => %{"enabled" => false, "credentials" => "missing"},
        "paired_devices" => 1
      })

    result =
      Checks.mobile(
        mobile_dir: mobile_dir,
        client: client,
        health_probe: fn _url, _timeout -> flunk("no candidate must not be probed") end
      )

    assert result.status == :fail
    assert result.detail =~ "no advertised candidates"
  end

  test "a stopped daemon warns without inventing local liveness", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    result =
      Checks.mobile(
        mobile_dir: mobile_dir,
        client: fn "mobile_status" -> {:error, :not_running} end
      )

    assert result.status == :warn
    assert result.detail =~ "daemon not running"
  end

  # A daemon that refused the surface this boot still answers its status, so
  # the refusal is a fact in the report rather than an error reply.
  test "a mobile surface the daemon refused to start names the refusal", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)
    Application.put_env(:fermix_channels, :mobile, enabled: true, push: [enabled: true])

    client = live_client(idle_report(%{"refused" => true}))

    result = Checks.mobile(mobile_dir: mobile_dir, client: client)

    assert result.status == :fail
    assert result.detail =~ "mobile surface refused this boot; see the daemon log"
    refute result.detail =~ "listener down"
    refute result.detail =~ "mDNS down"
    refute result.detail =~ "APNs"
  end

  test "a refusal names the class of fault the daemon published", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    client = live_client(idle_report(%{"refused" => true, "refusal" => "memory_disabled"}))

    result = Checks.mobile(mobile_dir: mobile_dir, client: client)

    assert result.status == :fail

    assert result.detail =~
             "mobile surface refused this boot (memory_disabled); see the daemon log"
  end

  # STB-6: a listener that cannot bind stays up and retries; doctor says why.
  test "a listener that cannot bind names why and that it retries", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)
    Application.put_env(:fermix_channels, :mobile, enabled: true, advertise_mdns: false)

    client =
      live_client(%{
        "listener" => %{
          "status" => "unavailable",
          "reason" => "address_unavailable",
          "candidates" => ["wss://100.64.0.1:4031/ws"]
        },
        "mdns" => "disabled",
        "tailnet" => %{"detected" => false, "candidates" => []},
        "apns" => %{"enabled" => false, "credentials" => "missing", "delivery" => "down"},
        "paired_devices" => 1
      })

    result =
      Checks.mobile(
        mobile_dir: mobile_dir,
        client: client,
        health_probe: fn _url, _timeout -> flunk("an unavailable listener is not probed") end
      )

    assert result.status == :fail
    assert result.detail =~ "listener unavailable (address_unavailable); it keeps retrying"
  end

  # STB-5: APNs unreachable degrades push instead of stopping the channel.
  test "degraded push is a warning that names why", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)

    Application.put_env(:fermix_channels, :mobile,
      enabled: true,
      advertise_mdns: false,
      push: [enabled: true]
    )

    client =
      live_client(%{
        "listener" => %{"status" => "ready", "candidates" => ["wss://lan:4031/ws"]},
        "mdns" => "disabled",
        "tailnet" => %{"detected" => false, "candidates" => []},
        "apns" => %{
          "enabled" => true,
          "credentials" => "ready",
          "delivery" => "degraded",
          "reason" => "connect_failed"
        },
        "paired_devices" => 1
      })

    result =
      Checks.mobile(
        mobile_dir: mobile_dir,
        client: client,
        health_probe: fn "https://lan:4031/healthz", 750 -> :ok end
      )

    assert result.status == :warn
    assert result.detail =~ "APNs degraded (connect_failed); the next push reconnects"
  end

  # R1-9: a connect that hangs used to leave the status read timing out, and
  # this check then said no dispatcher was running. It is a connect under way.
  test "push connecting to Apple is a warning that says so", %{mobile_dir: mobile_dir} do
    write_identity_files(mobile_dir)

    Application.put_env(:fermix_channels, :mobile,
      enabled: true,
      advertise_mdns: false,
      push: [enabled: true]
    )

    client =
      live_client(%{
        "listener" => %{"status" => "ready", "candidates" => ["wss://lan:4031/ws"]},
        "mdns" => "disabled",
        "tailnet" => %{"detected" => false, "candidates" => []},
        "apns" => %{
          "enabled" => true,
          "credentials" => "ready",
          "delivery" => "degraded",
          "reason" => "connecting"
        },
        "paired_devices" => 1
      })

    result =
      Checks.mobile(
        mobile_dir: mobile_dir,
        client: client,
        health_probe: fn "https://lan:4031/healthz", 750 -> :ok end
      )

    assert result.status == :warn
    assert result.detail =~ "APNs connecting to Apple"
    refute result.detail =~ "no push dispatcher"
  end

  # The switch reaches the daemon at once, but the channel starts only at boot:
  # an enabled channel that is not running needs a restart, not a probe.
  test "an enabled channel the daemon has not started asks for a restart", %{
    mobile_dir: mobile_dir
  } do
    write_identity_files(mobile_dir)
    Application.put_env(:fermix_channels, :mobile, enabled: true, advertise_mdns: true)

    client = live_client(idle_report(%{"refused" => false}))

    result = Checks.mobile(mobile_dir: mobile_dir, client: client)

    assert result.status == :fail
    assert result.detail =~ "mobile channel not started; restart the daemon"
    refute result.detail =~ "listener down"
    refute result.detail =~ "mDNS down"
    refute result.detail =~ "no paired devices"
  end

  test "listener, mDNS, APNs, and empty-pairing problems are not hidden", %{
    mobile_dir: mobile_dir
  } do
    write_identity_files(mobile_dir)

    Application.put_env(:fermix_channels, :mobile,
      enabled: true,
      advertise_mdns: true,
      push: [enabled: true]
    )

    client =
      live_client(%{
        "listener" => %{"status" => "down", "candidates" => []},
        "mdns" => "down",
        "tailnet" => %{"detected" => false, "candidates" => []},
        "apns" => %{"enabled" => true, "credentials" => "missing"},
        "paired_devices" => 0
      })

    result = Checks.mobile(mobile_dir: mobile_dir, client: client)

    assert result.status == :fail
    assert result.detail =~ "listener down"
    assert result.detail =~ "mDNS down"
    assert result.detail =~ "APNs credentials missing"
    assert result.detail =~ "no paired devices"
  end

  defp mobile_probe_detail(mobile_dir, port) do
    client =
      live_client(%{
        "listener" => %{"status" => "ready", "candidates" => ["wss://127.0.0.1:#{port}/ws"]},
        "mdns" => "advertising",
        "tailnet" => %{"detected" => false, "candidates" => []},
        "apns" => %{"enabled" => false, "credentials" => "missing"},
        "paired_devices" => 1
      })

    # The real probe over real TLS, under a bound a loaded machine cannot miss
    # (production probes with 750 ms).
    Checks.mobile(mobile_dir: mobile_dir, client: client, health_timeout_ms: 10_000).detail
  end

  # A loopback TLS listener that answers one /healthz request with `body`.
  defp start_health_server(body) do
    %{server_config: tls} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: @test_key, peer: @test_key},
        client_chain: %{root: @test_key, peer: @test_key}
      })

    {:ok, listen} = :ssl.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}] ++ tls)
    {:ok, {_address, port}} = :ssl.sockname(listen)
    _server = spawn_link(fn -> answer_health(listen, body) end)
    port
  end

  defp answer_health(listen, body) do
    {:ok, accepted} = :ssl.transport_accept(listen)
    {:ok, socket} = :ssl.handshake(accepted, 5_000)
    :ok = read_request(socket, "")

    :ok =
      :ssl.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )

    :ssl.close(socket)
  end

  defp read_request(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      :ok
    else
      {:ok, data} = :ssl.recv(socket, 0, 5_000)
      read_request(socket, received <> data)
    end
  end

  # The daemon's report for a channel that runs: the facts each case sets, plus
  # the lifecycle every running channel publishes.
  defp live_client(report) do
    report = Map.merge(%{"enabled" => true, "started" => true, "refused" => false}, report)
    fn "mobile_status" -> {:ok, %{"status" => "ok", "result" => report}} end
  end

  # A channel that is not running reports idle facts beside the reason.
  defp idle_report(lifecycle) do
    Map.merge(
      %{
        "started" => false,
        "listener" => %{"status" => "down", "candidates" => []},
        "mdns" => "down",
        "tailnet" => %{"detected" => false, "candidates" => []},
        "apns" => %{"enabled" => true, "credentials" => "missing"},
        "paired_devices" => 0
      },
      lifecycle
    )
  end

  defp write_identity_files(mobile_dir) do
    for name <- ~w(gateway_key tls.crt tls.key) do
      path = Path.join(mobile_dir, name)
      File.write!(path, "fixture")
      File.chmod!(path, 0o600)
    end
  end
end
