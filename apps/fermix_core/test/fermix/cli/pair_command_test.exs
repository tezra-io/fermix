defmodule Fermix.CLI.PairCommandTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.PairCommand

  @session_id "5b0c7d2e-8f41-4a6b-9c3d-2e7f1a8b4c60"
  @device_id "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"
  @uri "fermix://pair?v=1&port=4031&secret=one-time"
  @no_proof "This phone sent no secure-hardware proof."

  test "renders the QR, waits for a phone, and approves only after the code is confirmed" do
    script = %{
      "mobile.pair.start" => [started(120_000)],
      "mobile.pair.get" => [
        {:ok, view("awaiting_scan", ttl_ms: 119_000)},
        {:ok, view("awaiting_scan", ttl_ms: 118_000)},
        {:ok, view("awaiting_decision", ttl_ms: 117_000, request: request())}
      ],
      "mobile.pair.decide" => [approved()]
    }

    {status, stdout, stderr} = run_pair(script, "y\n")

    assert status == 0
    assert stdout =~ "██"
    assert stdout =~ "expires in 120s"
    assert stdout =~ "Manual pairing URI: #{@uri}"
    assert stdout =~ @no_proof

    assert stdout =~
             "Google Pixel 9 Pro 'Sam's phone' requests pairing. Phone shows 481062. Approve? [y/N]"

    assert stdout =~ "paired Sam's phone (#{@device_id})"
    assert stderr == ""

    assert_received {:call, "mobile.pair.start", %{}, [timeout: 5_000]}

    for _poll <- 1..3 do
      assert_received {:call, "mobile.pair.get", %{"session_id" => @session_id}, _opts}
      assert_received {:slept, 1_000}
    end

    refute_received {:call, "mobile.pair.get", _params, _opts}

    assert_received {:call, "mobile.pair.decide",
                     %{"session_id" => @session_id, "approved" => true}, [timeout: 5_000]}

    refute_received {:call, "mobile.pair.cancel", _params, _opts}
  end

  test "a blank answer denies through the daemon instead of approving" do
    {status, stdout, stderr} = run_pair(asking_script(denied()), "\n")

    assert status == 0
    assert_received {:call, "mobile.pair.decide", %{"approved" => false}, _opts}
    assert stdout =~ "pairing denied"
    assert stderr == ""
  end

  test "a closed input denies too" do
    {status, stdout, _stderr} = run_pair(asking_script(denied()), "")

    assert status == 0
    assert_received {:call, "mobile.pair.decide", %{"approved" => false}, _opts}
    assert stdout =~ "pairing denied"
  end

  # Nothing was opened, so nothing is polled or cancelled. The switch still
  # lives in `config.toml` on a host managed without the desktop app, so the
  # daemon's sentence is followed by where to flip it.
  test "a channel that is off prints the daemon's sentence and the config switch" do
    script = %{
      "mobile.pair.start" => [failed_start("unavailable", "The mobile channel is turned off.")]
    }

    {status, stdout, stderr} = run_pair(script, "")

    assert status == 1
    assert stdout == ""
    assert stderr =~ "fermix pair: The mobile channel is turned off."
    assert stderr =~ "[fermix_channels.mobile]"
    assert stderr =~ "enabled = true"
    assert stderr =~ "config.toml"
    assert stderr =~ "fermix restart"
    refute stderr =~ "fermix setup"
    refute_received {:call, "mobile.pair.get", _params, _opts}
    refute_received {:call, "mobile.pair.cancel", _params, _opts}
  end

  test "any other refused start prints the daemon's sentence alone" do
    sentence = "The mobile channel has not started yet. Restart Fermix to apply the change."
    script = %{"mobile.pair.start" => [failed_start("unavailable", sentence)]}

    {status, _stdout, stderr} = run_pair(script, "")

    assert status == 1
    assert stderr == "fermix pair: #{sentence}\n"
    refute_received {:call, "mobile.pair.cancel", _params, _opts}
  end

  test "a window already open is named as such" do
    busy =
      {:error,
       {:management_error, "busy",
        "Another management operation of this kind is already running.",
        %{"operation" => "mobile.pair"}}}

    {status, _stdout, stderr} = run_pair(%{"mobile.pair.start" => [busy]}, "")

    assert status == 1
    assert stderr == "fermix pair: a pairing window is already open\n"
  end

  test "daemon absence fails loudly without opening a second pairing path" do
    {status, stdout, stderr} = run_pair(%{"mobile.pair.start" => [{:error, :not_running}]}, "")

    assert status == 1
    assert stdout == ""
    assert stderr =~ "Fermix daemon is not running"
    assert stderr =~ "fermix start"
  end

  test "polling is bounded by the window plus five seconds, then the window is cancelled" do
    script = %{
      "mobile.pair.start" => [started(3_000)],
      "mobile.pair.get" => [{:ok, view("awaiting_scan", ttl_ms: 1_000)}],
      "mobile.pair.cancel" => [{:ok, view("cancelled", outcome: reason("cancelled"))}]
    }

    {status, _stdout, stderr} = run_pair(script, "")

    assert status == 1
    assert stderr =~ "the daemon never closed the pairing window"
    assert calls("mobile.pair.get") == 8
    assert_received {:call, "mobile.pair.cancel", %{"session_id" => @session_id}, _opts}
  end

  test "a failure after the window opened cancels it before failing" do
    script = %{
      "mobile.pair.start" => [started(120_000)],
      "mobile.pair.get" => [{:error, :closed}],
      "mobile.pair.cancel" => [{:ok, view("cancelled", outcome: reason("cancelled"))}]
    }

    {status, stdout, stderr} = run_pair(script, "")

    assert status == 1
    assert stdout =~ "██"
    assert stderr =~ "fermix pair: :closed"
    refute stderr =~ "cleanup failed"

    assert_received {:call, "mobile.pair.cancel", %{"session_id" => @session_id},
                     [timeout: 5_000]}
  end

  test "a cancel that fails too is reported beside the first failure" do
    script = %{
      "mobile.pair.start" => [started(120_000)],
      "mobile.pair.get" => [{:error, :closed}],
      "mobile.pair.cancel" => [{:error, :not_running}]
    }

    {status, _stdout, stderr} = run_pair(script, "")

    assert status == 1
    assert stderr =~ "fermix pair: :closed; pairing cleanup failed: the daemon stopped answering"
  end

  test "a window that closes on its own says how it ended, with nothing to cancel" do
    script = %{
      "mobile.pair.start" => [started(120_000)],
      "mobile.pair.get" => [{:ok, view("expired", outcome: reason("timeout"))}]
    }

    {status, _stdout, stderr} = run_pair(script, "")

    assert status == 1
    assert stderr == "fermix pair: pairing ended (timeout)\n"
    refute_received {:call, "mobile.pair.decide", _params, _opts}
    refute_received {:call, "mobile.pair.cancel", _params, _opts}
  end

  test "a session decided from another client reports its outcome" do
    script = %{
      "mobile.pair.start" => [started(120_000)],
      "mobile.pair.get" => [approved()]
    }

    {status, stdout, _stderr} = run_pair(script, "")

    assert status == 0
    assert stdout =~ "paired Sam's phone (#{@device_id})"
    refute_received {:call, "mobile.pair.decide", _params, _opts}
  end

  test "a phone gone before the decision ends the run in the daemon's words" do
    sentence = "The phone disconnected before you decided. Start pairing again."
    failed = view("failed", request: request(), failure: failure("refused", sentence))

    {status, _stdout, stderr} = run_pair(asking_script({:ok, failed}), "y\n")

    assert status == 1
    assert stderr == "fermix pair: #{sentence}\n"
    refute_received {:call, "mobile.pair.cancel", _params, _opts}
  end

  test "a management refusal is rendered in the daemon's own sentence, not its code" do
    refusal =
      {:error,
       {:management_error, "invalid_params", "Request parameters are invalid.",
        %{"field" => "session_id", "sentence" => "No phone is waiting for a decision."}}}

    script =
      asking_script(refusal)
      |> Map.put("mobile.pair.cancel", [{:ok, view("cancelled", outcome: reason("cancelled"))}])

    {status, _stdout, stderr} = run_pair(script, "y\n")

    assert status == 1
    assert stderr == "fermix pair: No phone is waiting for a decision.\n"
    assert_received {:call, "mobile.pair.cancel", %{"session_id" => @session_id}, _opts}
  end

  test "a start view the command cannot trust is closed rather than shown" do
    untrusted = {:ok, Map.put(view("awaiting_scan", ttl_ms: 120_000), "uri", "https://example")}

    script = %{
      "mobile.pair.start" => [untrusted],
      "mobile.pair.cancel" => [{:ok, view("cancelled", outcome: reason("cancelled"))}]
    }

    {status, stdout, stderr} = run_pair(script, "")

    assert status == 1
    assert stdout == ""
    assert stderr =~ "invalid pairing window"
    assert_received {:call, "mobile.pair.cancel", %{"session_id" => @session_id}, _opts}
  end

  test "device-supplied text can never repaint the approval prompt or the paired line" do
    ansi_name = "\e[2K\rApproved\u{009B}31m"
    asked = request(%{"device_name" => ansi_name, "model" => "Pixel\t9"})

    approved =
      {:ok,
       view("approved", request: asked, outcome: %{"device_id" => @device_id, "reason" => nil})}

    script = %{
      "mobile.pair.start" => [started(120_000)],
      "mobile.pair.get" => [{:ok, view("awaiting_decision", ttl_ms: 90_000, request: asked)}],
      "mobile.pair.decide" => [approved]
    }

    {status, stdout, _stderr} = run_pair(script, "y\n")

    assert status == 0
    refute stdout =~ "\e"
    refute stdout =~ "\u{009B}"
    refute stdout =~ "\r"
    refute stdout =~ "\t"
    assert stdout =~ "Approved"
    assert stdout =~ "Phone shows 481062"
    assert stdout =~ "paired"
  end

  test "rejects arguments before making a call" do
    {:ok, stdin} = StringIO.open("")
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")

    assert PairCommand.run(["--yes"],
             client: fn _method, _params, _opts -> flunk("no call may run") end,
             stdin: stdin,
             stdout: stdout,
             stderr: stderr
           ) == 2

    assert output(stdout) == ""
    assert output(stderr) =~ "usage: fermix pair"
  end

  # A phone asks on the first poll, and the decision answers `decided`.
  defp asking_script(decided) do
    %{
      "mobile.pair.start" => [started(120_000)],
      "mobile.pair.get" => [{:ok, view("awaiting_decision", ttl_ms: 90_000, request: request())}],
      "mobile.pair.decide" => [decided]
    }
  end

  defp run_pair(script, input) do
    test_pid = self()
    daemon = start_supervised!({Agent, fn -> script end})
    {:ok, stdin} = StringIO.open(input)
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")

    client = fn method, params, opts ->
      send(test_pid, {:call, method, params, opts})
      Agent.get_and_update(daemon, &next_reply(&1, method))
    end

    status =
      PairCommand.run([],
        client: client,
        poll_sleep: fn ms -> send(test_pid, {:slept, ms}) end,
        stdin: stdin,
        stdout: stdout,
        stderr: stderr
      )

    {status, output(stdout), output(stderr)}
  end

  # Each method answers its queued replies in order, and the last one repeats.
  defp next_reply(script, method) do
    case Map.get(script, method) do
      [reply] -> {reply, script}
      [reply | rest] -> {reply, Map.put(script, method, rest)}
      nil -> {{:error, {:unscripted, method}}, script}
    end
  end

  defp calls(method) do
    receive do
      {:call, ^method, _params, _opts} -> 1 + calls(method)
    after
      0 -> 0
    end
  end

  defp started(ttl_ms), do: {:ok, Map.put(view("awaiting_scan", ttl_ms: ttl_ms), "uri", @uri)}

  defp approved do
    {:ok,
     view("approved", request: request(), outcome: %{"device_id" => @device_id, "reason" => nil})}
  end

  defp denied, do: {:ok, view("denied", request: request(), outcome: reason("denied"))}

  defp failed_start(code, sentence) do
    {:ok,
     %{
       "session_id" => nil,
       "state" => "failed",
       "ttl_ms" => nil,
       "request" => nil,
       "outcome" => nil,
       "failure" => failure(code, sentence),
       "uri" => nil
     }}
  end

  defp view(state, fields) do
    Map.merge(
      %{
        "session_id" => @session_id,
        "state" => state,
        "ttl_ms" => nil,
        "request" => nil,
        "outcome" => nil,
        "failure" => nil
      },
      Map.new(fields, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp request(fields \\ %{}) do
    Map.merge(
      %{
        "device_name" => "Sam's phone",
        "model" => "Google Pixel 9 Pro",
        "platform" => nil,
        "app_version" => "1.0.0",
        "sas" => "481062",
        "build_role" => nil,
        "boot_state" => nil,
        "attestation" => %{"status" => "unavailable", "sentence" => @no_proof}
      },
      fields
    )
  end

  defp reason(reason), do: %{"device_id" => nil, "reason" => reason}
  defp failure(code, sentence), do: %{"code" => code, "sentence" => sentence}

  defp output(device) do
    {_input, output} = StringIO.contents(device)
    output
  end
end
