defmodule Fermix.CLI.Doctor.MobileCheckTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Doctor.Checks
  alias FermixTestSupport.SafeRm

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

  test "enabled mobile fails when its identity files do not exist", %{mobile_dir: mobile_dir} do
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    result = Checks.mobile(mobile_dir: mobile_dir, client: fn _ -> flunk("no RPC") end)

    assert result.status == :fail
    assert result.detail =~ "missing"
    assert result.detail =~ "fermix pair"
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
        "apns" => %{"enabled" => true, "credentials" => "ready"},
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

  defp live_client(report) do
    fn "mobile_status" -> {:ok, %{"status" => "ok", "result" => report}} end
  end

  defp write_identity_files(mobile_dir) do
    for name <- ~w(gateway_key tls.crt tls.key) do
      path = Path.join(mobile_dir, name)
      File.write!(path, "fixture")
      File.chmod!(path, 0o600)
    end
  end
end
