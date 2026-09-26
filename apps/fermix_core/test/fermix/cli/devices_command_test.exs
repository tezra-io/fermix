defmodule Fermix.CLI.DevicesCommandTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.DevicesCommand

  @device_id "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"

  test "list prints the four operator columns of each phone and nothing else" do
    client = fn "mobile.devices.list", %{}, opts ->
      assert opts[:timeout] <= 5_000

      {:ok,
       %{
         "devices" => [
           device(%{
             "last_seen" => "2026-09-26T12:30:00Z",
             "push_registered" => true,
             "noise_pk" => "must-not-print"
           })
         ]
       }}
    end

    {status, stdout, stderr} = run(["list"], client)

    assert status == 0

    assert stdout ==
             "DEVICE ID\tNAME\tCREATED\tLAST SEEN\n" <>
               "#{@device_id}\tSam's phone\t2026-09-26T12:01:05Z\t2026-09-26T12:30:00Z\n"

    refute stdout =~ "must-not-print"
    refute stdout =~ "Google Pixel"
    assert stderr == ""
  end

  test "a phone never seen since pairing says so" do
    client = fn "mobile.devices.list", %{}, _opts -> {:ok, %{"devices" => [device()]}} end

    {0, stdout, _stderr} = run(["list"], client)

    assert stdout =~ "2026-09-26T12:01:05Z\tnever\n"
  end

  test "list strips every terminal control sequence a stored name could carry" do
    client = fn "mobile.devices.list", %{}, _opts ->
      {:ok, %{"devices" => [device(%{"name" => "\e[2KSam\u{009B}31m"})]}}
    end

    {status, stdout, stderr} = run(["list"], client)

    assert status == 0
    assert stdout =~ "Sam"
    refute stdout =~ "\e"
    refute stdout =~ "\u{009B}"
    assert stderr == ""
  end

  test "list renders no paired phone clearly" do
    client = fn "mobile.devices.list", %{}, _opts -> {:ok, %{"devices" => []}} end

    assert run(["list"], client) == {0, "no paired phones\n", ""}
  end

  test "a row the command cannot trust is refused rather than printed" do
    client = fn "mobile.devices.list", %{}, _opts ->
      {:ok, %{"devices" => [device(%{"device_id" => "../../devices.toml"})]}}
    end

    {status, stdout, stderr} = run(["list"], client)

    assert status == 1
    assert stdout == ""
    assert stderr =~ "invalid device row"
  end

  test "revoke sends the exact UUID and expects the daemon to confirm it" do
    test_pid = self()

    client = fn "mobile.devices.revoke", %{"device_id" => @device_id}, opts ->
      send(test_pid, {:revoked, opts[:timeout]})
      {:ok, %{"device_id" => @device_id, "revoked" => true}}
    end

    assert run(["revoke", String.upcase(@device_id)], client) ==
             {0, "revoked phone #{@device_id}\n", ""}

    assert_received {:revoked, timeout}
    assert timeout <= 5_000
  end

  test "a revoke the daemon does not confirm is a failure" do
    client = fn "mobile.devices.revoke", _params, _opts ->
      {:ok, %{"device_id" => @device_id, "revoked" => false}}
    end

    {status, stdout, stderr} = run(["revoke", @device_id], client)

    assert status == 1
    assert stdout == ""
    assert stderr =~ "invalid daemon reply"
  end

  test "revoking an unknown phone renders the daemon's sentence, not its code" do
    client = fn "mobile.devices.revoke", %{"device_id" => _id}, _opts ->
      {:error,
       {:management_error, "invalid_params", "Request parameters are invalid.",
        %{"field" => "device_id", "sentence" => "No paired phone has that id."}}}
    end

    {status, _stdout, stderr} = run(["revoke", @device_id], client)

    assert status == 1
    assert stderr == "fermix devices revoke: No paired phone has that id.\n"
  end

  test "revoking while the phone channel is not running says where to look" do
    client = fn "mobile.devices.revoke", _params, _opts ->
      {:error,
       {:management_error, "unavailable", "The requested management capability is unavailable.",
        %{"capability" => "mobile"}}}
    end

    {status, _stdout, stderr} = run(["revoke", @device_id], client)

    assert status == 1
    assert stderr =~ "the phone channel is not running"
    assert stderr =~ "fermix doctor"
  end

  test "rejects malformed ids before calling the daemon" do
    client = fn _method, _params, _opts -> flunk("no call may run") end

    {status, stdout, stderr} = run(["revoke", "../../devices.toml"], client)

    assert status == 2
    assert stdout == ""
    assert stderr =~ "valid device UUID"
  end

  test "daemon absence is an error for both verbs; there is no offline store path" do
    client = fn _method, _params, _opts -> {:error, :not_running} end

    for argv <- [["list"], ["revoke", @device_id]] do
      {status, stdout, stderr} = run(argv, client)

      assert status == 1
      assert stdout == ""
      assert stderr =~ "Fermix daemon is not running"
    end
  end

  test "a daemon that does not speak the management protocol is named" do
    client = fn "mobile.devices.list", %{}, _opts -> {:error, :invalid_management_response} end

    {status, _stdout, stderr} = run(["list"], client)

    assert status == 1
    assert stderr =~ "fermix devices list: the daemon did not answer management protocol v1"
  end

  test "invalid verbs return usage status" do
    client = fn _method, _params, _opts -> flunk("no call may run") end

    {status, stdout, stderr} = run(["delete", @device_id], client)

    assert status == 2
    assert stdout == ""
    assert stderr =~ "usage: fermix devices list"
    assert stderr =~ "fermix devices revoke <device_id>"
  end

  defp run(argv, client) do
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")
    status = DevicesCommand.run(argv, client: client, stdout: stdout, stderr: stderr)
    {status, output(stdout), output(stderr)}
  end

  defp device(fields \\ %{}) do
    Map.merge(
      %{
        "device_id" => @device_id,
        "name" => "Sam's phone",
        "model" => "Google Pixel 9 Pro",
        "platform" => nil,
        "signer_role" => nil,
        "boot_state" => nil,
        "push_registered" => false,
        "created_at" => "2026-09-26T12:01:05Z",
        "last_seen" => nil
      },
      fields
    )
  end

  defp output(device) do
    {_input, output} = StringIO.contents(device)
    output
  end
end
