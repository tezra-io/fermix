defmodule FermixCore.Setup.MobileDoctorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.Doctor

  setup do
    original = Application.get_env(:fermix_channels, :mobile)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_channels, :mobile)
        value -> Application.put_env(:fermix_channels, :mobile, value)
      end
    end)

    :ok
  end

  test "disabled mobile reports locally without contacting the daemon" do
    Application.put_env(:fermix_channels, :mobile, enabled: false)
    client = fn _method -> flunk("disabled mobile must not contact the daemon") end

    assert Doctor.mobile_report(client: client) == %{enabled: false, status: :disabled}
  end

  test "enabled mobile returns the daemon's live listener report" do
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    report = %{
      "listener" => %{"status" => "ready", "candidates" => ["192.168.1.10"]},
      "mdns" => "advertising",
      "tailnet" => %{"detected" => false, "candidates" => []},
      "apns" => %{"enabled" => false, "credentials" => "missing"},
      "paired_devices" => 1
    }

    client = fn "mobile_status" ->
      {:ok, %{"status" => "ok", "result" => report}}
    end

    assert Doctor.mobile_report(client: client) == %{
             enabled: true,
             status: :reported,
             report: report
           }
  end

  test "distinguishes a stopped daemon from a malformed response" do
    Application.put_env(:fermix_channels, :mobile, enabled: true)

    assert Doctor.mobile_report(client: fn "mobile_status" -> {:error, :not_running} end) == %{
             enabled: true,
             status: :daemon_not_running
           }

    malformed = Doctor.mobile_report(client: fn "mobile_status" -> {:ok, %{}} end)
    assert malformed.enabled == true
    assert malformed.status == :error
    assert malformed.error =~ "unexpected"
  end
end
