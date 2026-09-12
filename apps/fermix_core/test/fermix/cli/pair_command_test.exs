defmodule Fermix.CLI.PairCommandTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.PairCommand

  @session_id "pair-session-1"
  @device_id "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"

  test "renders the daemon QR, verifies the SAS, and approves only after confirmation" do
    test_pid = self()

    request = fn
      "mobile_pair_begin", %{}, timeout ->
        send(test_pid, {:rpc, :begin, timeout})

        ok(%{
          "session_id" => @session_id,
          "uri" => "fermix://pair?v=1&secret=one-time",
          "qr" => "QR BLOCKS",
          "expires_in_s" => 120
        })

      "mobile_pair_wait", %{"session_id" => @session_id}, timeout ->
        send(test_pid, {:rpc, :wait, timeout})

        ok(%{
          "name" => "Sujeeth",
          "model" => "iPhone 16 Pro",
          "sas" => "047291"
        })

      "mobile_pair_decide", %{"session_id" => @session_id, "approved" => true}, timeout ->
        send(test_pid, {:rpc, :decide, timeout})
        ok(%{"approved" => true, "device_id" => @device_id, "name" => "Sujeeth"})
    end

    {stdin, stdout, stderr} = io("y\n")

    assert PairCommand.run([],
             with_connection: connection(request),
             stdin: stdin,
             stdout: stdout,
             stderr: stderr
           ) ==
             0

    assert output(stdout) =~ "QR BLOCKS"
    assert output(stdout) =~ "fermix://pair?v=1&secret=one-time"
    assert output(stdout) =~ "iPhone 16 Pro 'Sujeeth' requests pairing"
    assert output(stdout) =~ "Phone shows 047291"
    assert output(stdout) =~ "paired Sujeeth (#{@device_id})"
    assert output(stderr) == ""

    assert_received {:rpc, :begin, begin_timeout}
    assert begin_timeout <= 5_000
    assert_received {:rpc, :wait, wait_timeout}
    assert wait_timeout >= 120_000 and wait_timeout <= 125_000
    assert_received {:rpc, :decide, decide_timeout}
    assert decide_timeout <= 5_000
  end

  test "blank confirmation denies through the daemon instead of auto-approving" do
    test_pid = self()

    request = fn
      "mobile_pair_begin", %{}, _timeout ->
        ok(%{
          "session_id" => @session_id,
          "uri" => "fermix://pair?v=1",
          "qr" => "QR",
          "expires_in_s" => 120
        })

      "mobile_pair_wait", %{"session_id" => @session_id}, _timeout ->
        ok(%{
          "name" => "Phone",
          "model" => "iPhone",
          "sas" => "123456"
        })

      "mobile_pair_decide", %{"session_id" => @session_id, "approved" => false}, _timeout ->
        send(test_pid, :denied)
        ok(%{"approved" => false})
    end

    {stdin, stdout, stderr} = io("\n")

    assert PairCommand.run([],
             with_connection: connection(request),
             stdin: stdin,
             stdout: stdout,
             stderr: stderr
           ) ==
             0

    assert_received :denied
    assert output(stdout) =~ "pairing denied"
    assert output(stderr) == ""
  end

  test "daemon absence fails loudly without opening a second pairing path" do
    {stdin, stdout, stderr} = io("")

    assert PairCommand.run([],
             with_connection: fn _callback -> {:error, :not_running} end,
             stdin: stdin,
             stdout: stdout,
             stderr: stderr
           ) ==
             1

    assert output(stdout) == ""
    assert output(stderr) =~ "Fermix daemon is not running"
    assert output(stderr) =~ "fermix start"
  end

  test "cancels the daemon pairing window when a post-open step fails" do
    test_pid = self()

    request = fn
      "mobile_pair_begin", %{}, _timeout ->
        ok(%{
          "session_id" => @session_id,
          "uri" => "fermix://pair?v=1",
          "qr" => "QR",
          "expires_in_s" => 120
        })

      "mobile_pair_wait", %{"session_id" => @session_id}, _timeout ->
        {:ok, %{"status" => "error", "reason" => "connection_lost"}}

      "mobile_pair_cancel", %{"session_id" => @session_id}, timeout ->
        send(test_pid, {:cancelled, timeout})
        ok(%{"cancelled" => true})
    end

    {stdin, stdout, stderr} = io("")

    assert PairCommand.run([],
             with_connection: connection(request),
             stdin: stdin,
             stdout: stdout,
             stderr: stderr
           ) ==
             1

    assert_received {:cancelled, timeout}
    assert timeout <= 5_000
    assert output(stdout) =~ "QR"
    assert output(stderr) =~ "connection_lost"
  end

  test "device-supplied text can never repaint the approval prompt or the paired line" do
    ansi_name = "\e[2K\rApproved\u{009B}31m"

    request = fn
      "mobile_pair_begin", %{}, _timeout ->
        ok(%{
          "session_id" => @session_id,
          "uri" => "fermix://pair?v=1",
          "qr" => "QR",
          "expires_in_s" => 120
        })

      "mobile_pair_wait", %{"session_id" => @session_id}, _timeout ->
        ok(%{"name" => ansi_name, "model" => "iPhone\t16", "sas" => "047291"})

      "mobile_pair_decide", %{"session_id" => @session_id, "approved" => true}, _timeout ->
        ok(%{"approved" => true, "device_id" => @device_id, "name" => ansi_name})
    end

    {stdin, stdout, stderr} = io("y\n")

    assert PairCommand.run([],
             with_connection: connection(request),
             stdin: stdin,
             stdout: stdout,
             stderr: stderr
           ) == 0

    printed = output(stdout)
    refute printed =~ "\e"
    refute printed =~ "\u{009B}"
    refute printed =~ "\r"
    refute printed =~ "\t"
    assert printed =~ "Approved"
    assert printed =~ "Phone shows 047291"
    assert printed =~ "paired"
  end

  test "an approval whose phone already disconnected explains the retry" do
    request = fn
      "mobile_pair_begin", %{}, _timeout ->
        ok(%{
          "session_id" => @session_id,
          "uri" => "fermix://pair?v=1",
          "qr" => "QR",
          "expires_in_s" => 120
        })

      "mobile_pair_wait", %{"session_id" => @session_id}, _timeout ->
        ok(%{"name" => "Phone", "model" => "iPhone", "sas" => "123456"})

      "mobile_pair_decide", %{"session_id" => @session_id, "approved" => true}, _timeout ->
        {:ok, %{"status" => "error", "reason" => "device_disconnected"}}

      "mobile_pair_cancel", %{"session_id" => @session_id}, _timeout ->
        ok(%{"cancelled" => true})
    end

    {stdin, stdout, stderr} = io("y\n")

    assert PairCommand.run([],
             with_connection: connection(request),
             stdin: stdin,
             stdout: stdout,
             stderr: stderr
           ) == 1

    assert output(stderr) =~ "phone disconnected"
    assert output(stderr) =~ "re-run pairing"
    refute output(stderr) =~ "cleanup failed"
  end

  # The mobile channel has no setup surface: `config.toml` is the only enable
  # path, so the refusal has to name the flag and the restart, and must never
  # send the operator to `fermix setup` or the web setup for a switch neither
  # one owns.
  test "a disabled mobile channel points at the config flag, not at setup" do
    request = fn "mobile_pair_begin", %{}, _timeout ->
      {:ok, %{"status" => "error", "reason" => "mobile_disabled"}}
    end

    {stdin, stdout, stderr} = io("")

    assert PairCommand.run([],
             with_connection: connection(request),
             stdin: stdin,
             stdout: stdout,
             stderr: stderr
           ) == 1

    printed = output(stderr)
    assert printed =~ "[fermix_channels.mobile]"
    assert printed =~ "enabled = true"
    assert printed =~ "config.toml"
    assert printed =~ "fermix restart"
    refute printed =~ "fermix setup"
    refute printed =~ "setup page"
  end

  test "rejects arguments before making an RPC" do
    request = fn _method, _params, _timeout -> flunk("RPC must not run") end
    {stdin, stdout, stderr} = io("")

    assert PairCommand.run(["--yes"],
             with_connection: connection(request),
             stdin: stdin,
             stdout: stdout,
             stderr: stderr
           ) == 2

    assert output(stdout) == ""
    assert output(stderr) =~ "usage: fermix pair"
  end

  defp ok(result), do: {:ok, %{"status" => "ok", "result" => result}}

  defp connection(request), do: fn callback -> callback.(request) end

  defp io(input) do
    {:ok, stdin} = StringIO.open(input)
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")
    {stdin, stdout, stderr}
  end

  defp output(device) do
    {_input, output} = StringIO.contents(device)
    output
  end
end
