defmodule Fermix.CLI.DevicesCommandTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.DevicesCommand

  @device_id "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"

  test "list prints only operator-safe device fields" do
    request = fn "mobile_devices_list", %{}, timeout ->
      assert timeout <= 5_000

      ok(%{
        "devices" => [
          %{
            "device_id" => @device_id,
            "name" => "Sujeeth",
            "created_at" => "2026-08-12T12:00:00Z",
            "last_seen" => "2026-08-12T12:30:00Z",
            "noise_pk" => "must-not-print",
            "push_token" => "must-not-print-either"
          }
        ]
      })
    end

    {stdout, stderr} = io()

    assert DevicesCommand.run(["list"], request: request, stdout: stdout, stderr: stderr) == 0
    assert output(stdout) =~ @device_id
    assert output(stdout) =~ "Sujeeth"
    assert output(stdout) =~ "2026-08-12T12:00:00Z"
    assert output(stdout) =~ "2026-08-12T12:30:00Z"
    refute output(stdout) =~ "must-not-print"
    assert output(stderr) == ""
  end

  test "list renders an empty store clearly" do
    request = fn "mobile_devices_list", %{}, _timeout -> ok(%{"devices" => []}) end
    {stdout, stderr} = io()

    assert DevicesCommand.run(["list"], request: request, stdout: stdout, stderr: stderr) == 0
    assert output(stdout) == "no paired mobile devices\n"
    assert output(stderr) == ""
  end

  test "revoke sends the exact UUID to the running daemon" do
    test_pid = self()

    request = fn "mobile_device_revoke", %{"device_id" => @device_id}, timeout ->
      send(test_pid, {:revoked, timeout})
      ok(%{"device_id" => @device_id})
    end

    {stdout, stderr} = io()

    assert DevicesCommand.run(["revoke", @device_id],
             request: request,
             stdout: stdout,
             stderr: stderr
           ) == 0

    assert_received {:revoked, timeout}
    assert timeout <= 5_000
    assert output(stdout) == "revoked mobile device #{@device_id}\n"
    assert output(stderr) == ""
  end

  test "rejects malformed ids before calling the daemon" do
    request = fn _method, _params, _timeout -> flunk("RPC must not run") end
    {stdout, stderr} = io()

    assert DevicesCommand.run(["revoke", "../../devices.toml"],
             request: request,
             stdout: stdout,
             stderr: stderr
           ) == 2

    assert output(stdout) == ""
    assert output(stderr) =~ "valid device UUID"
  end

  test "daemon absence is an error for list; there is no offline store path" do
    request = fn "mobile_devices_list", %{}, _timeout -> {:error, :not_running} end
    {stdout, stderr} = io()

    assert DevicesCommand.run(["list"], request: request, stdout: stdout, stderr: stderr) == 1
    assert output(stdout) == ""
    assert output(stderr) =~ "Fermix daemon is not running"
  end

  test "invalid verbs return usage status" do
    request = fn _method, _params, _timeout -> flunk("RPC must not run") end
    {stdout, stderr} = io()

    assert DevicesCommand.run(["delete", @device_id],
             request: request,
             stdout: stdout,
             stderr: stderr
           ) == 2

    assert output(stdout) == ""
    assert output(stderr) =~ "usage: fermix devices list"
    assert output(stderr) =~ "fermix devices revoke <device_id>"
  end

  defp ok(result), do: {:ok, %{"status" => "ok", "result" => result}}

  defp io do
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")
    {stdout, stderr}
  end

  defp output(device) do
    {_input, output} = StringIO.contents(device)
    output
  end
end
