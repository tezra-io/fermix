defmodule FermixCore.Capabilities.AccessGateDeviceTest do
  @moduledoc """
  M75 §11: a command `device_action` would run on the owner's desktop, and a
  read grant it would record there, waits for the owner every time, on a card
  of kind `device` that names the desktop and the exact command or folder and
  waits as long as the action's deadline, and only the confirmed call runs: a
  different command, or the same one on another desktop, is not covered by
  that yes. Once it ran, the same call in the request it resumes gets the
  confirmed call's own result back (the command's output), never a second run.

  Each test parks in its own `AccessGate.Pending` and registry, and the
  desktops are the configured double's, scripted in this test's own process.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Tools.DeviceAction
  alias FermixTestSupport.DeviceActionsDouble
  alias FermixTestSupport.TelemetryCapture

  @token "TOKEN123"
  @mac %{device_id: "desk-mac-1", name: "Studio Mac", executor: true, connected: true}
  @attic %{device_id: "desk-lin-2", name: "Attic Linux", executor: true, connected: true}
  @command %{
    "action" => "run_command",
    "command" => "du -sh ~/Downloads",
    "device" => "Studio Mac"
  }

  setup do
    sid = "gate-device-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: sid)

    registry = :"gate_device_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, capability())
    pending = :"gate_device_pending_#{System.unique_integer([:positive])}"
    start_supervised!({Pending, name: pending})

    DeviceActionsDouble.install([@mac, @attic], fn _id, _action, args, _opts ->
      {:ok,
       %{
         kind: :result,
         status: :ok,
         result: %{"exit_code" => 0, "output" => "4.0G\t#{args["command"]}", "truncated" => false},
         attachment: nil,
         invocation_id: "inv-confirmed"
       }}
    end)

    %{sid: sid, registry: registry, pending: pending}
  end

  defp capability, do: Builtin.from_tool_module(DeviceAction)

  defp chat(ctx, extra \\ %{}) do
    test_pid = self()

    Map.merge(
      %{
        source_trust: :operator,
        computer_use_origin: :interactive,
        session_id: ctx.sid,
        agent_name: "main",
        channel: "companion",
        conversation_key: {"companion", ctx.sid, :root},
        capability_registry: ctx.registry,
        access_pending: ctx.pending,
        outside_sources: MapSet.new(),
        reply_fn: fn part -> send(test_pid, {:reply, part}) end,
        approval_fn: fn request ->
          send(test_pid, {:approval, request})
          {:ok, @token, store_answer(request)}
        end
      },
      extra
    )
  end

  # The channel confirmations store dedupes per origin, as in AccessGateTest.
  defp store_answer(%{access_sensitive: id}) do
    seen = Process.get(:live_tokens, MapSet.new())
    Process.put(:live_tokens, MapSet.put(seen, id))
    if MapSet.member?(seen, id), do: :existing, else: :new
  end

  defp execute(args, context), do: Capability.execute(capability(), args, context)

  test "a command for a connected desktop is held, even on a clean owner turn", ctx do
    assert {:ok, %{success: false, error: error, access_waiting: true}} =
             execute(@command, chat(ctx))

    assert error =~ "acts on the owner's other computer"
    assert error =~ "every such action waits for the owner's approval"
    assert error =~ "an approval card is now in this chat for 120 seconds"
    assert error =~ "call device_action with the same arguments and its result comes back"
    refute_received {:device_action_invoked, _id, _action, _args, _opts}

    assert_received {:telemetry, [:fermix, :tool, :exec], _measurements,
                     %{access_gate: "held_this_chat", policy_enforcement: marker}}

    assert marker == AccessGate.pre_execution_marker(:confirm)
  end

  test "the card is of kind device and names the desktop and the exact command", ctx do
    execute(@command, chat(ctx))

    assert_received {:approval, %{access_sensitive: _id, card: :device}}
    assert_received {:reply, {:approval_prompt, %{kind: :device, token: @token, text: text}}}
    assert text =~ "Run this command on your Studio Mac?"
    assert text =~ "Computer: Studio Mac"
    assert text =~ "Command: du -sh ~/Downloads"
    assert text =~ "/confirm #{@token}"
  end

  test "the owner's yes runs exactly the parked command on the parked desktop, once", ctx do
    execute(@command, chat(ctx))
    assert_received {:approval, %{access_sensitive: id}}

    assert {:ok, outcome} = AccessGate.confirm(id, ctx.pending)
    assert outcome =~ "device_action ran: Ran on your Studio Mac (exit 0)"

    assert_received {:device_action_invoked, "desk-mac-1", "run_command", sent, _opts}
    assert sent == %{"command" => "du -sh ~/Downloads"}

    assert_received {:telemetry, [:fermix, :tool, :exec], _measurements,
                     %{access_gate: "confirmed", access_intent: ^id}}

    assert {:error, _gone} = AccessGate.confirm(id, ctx.pending)
    refute_received {:device_action_invoked, _id, _action, _args, _opts}
  end

  test "the yes covers neither a different command nor another desktop", ctx do
    digest = AccessGate.digest("device_action", @command)

    for other <- [
          %{@command | "command" => "rm -rf ~/Downloads"},
          %{@command | "device" => "Attic Linux"}
        ] do
      assert {:ok, %{success: false, error: error}} =
               execute(other, chat(ctx, %{access_confirmed: digest}))

      assert error =~ "does not match the request the owner confirmed"
    end

    refute_received {:device_action_invoked, _id, _action, _args, _opts}
  end

  test "a changed command after a yes is parked again, with its own card", ctx do
    execute(@command, chat(ctx))
    assert_received {:approval, %{access_sensitive: first}}
    assert {:ok, _outcome} = AccessGate.confirm(first, ctx.pending)
    assert_received {:device_action_invoked, _id, "run_command", _args, _opts}

    execute(%{@command | "command" => "du -sh ~/Desktop"}, chat(ctx))
    assert_received {:approval, %{access_sensitive: second, card: :device}}
    refute second == first
    refute_received {:device_action_invoked, _id, _action, _args, _opts}
  end

  test "a command for an unavailable desktop asks nothing and runs nothing", ctx do
    DeviceActionsDouble.install([%{@mac | connected: false}], fn _id, _action, _args, _opts ->
      flunk("nothing is sent to an unavailable desktop")
    end)

    assert {:ok, %{success: false, error: "Your Studio Mac is unavailable; nothing was run."}} =
             execute(@command, chat(ctx))

    refute_received {:approval, _request}
    refute_received {:reply, _part}
  end

  test "every other action runs on the owner's word, without a card", ctx do
    args = %{"action" => "notify", "title" => "Tea", "body" => "Kettle", "device" => "Studio Mac"}
    assert {:ok, %{success: true}} = execute(args, chat(ctx))
    refute_received {:approval, _request}
    assert_received {:device_action_invoked, "desk-mac-1", "notify", _args, _opts}
  end

  test "a voice call, a worker, a cue run and a scheduled job never get a command run", ctx do
    scheduled =
      chat(ctx)
      |> Map.drop([:computer_use_origin, :reply_fn, :approval_fn])
      |> Map.put(:job_id, "job_1")

    refusals = [
      {chat(ctx, %{computer_use_origin: :voice, voice_call_id: "call-1"}), "voice call"},
      {chat(ctx, %{subagent_depth: 1}), "delegated worker"},
      {scheduled, "Only a turn the owner is present for"}
    ]

    for {context, words} <- refusals do
      assert {:ok, %{success: false, error: error}} = execute(@command, context)
      assert error =~ "runs only once the owner approves it"
      assert error =~ words
    end

    # A cue run meets its mandate gate first, which refuses any tool outside
    # the run's own tool set.
    assert {:ok, %{success: false, error: error}} =
             execute(@command, Map.put(scheduled, :trigger, "cue"))

    assert error =~ "cue run"

    refute_received {:approval, _request}
    refute_received {:device_action_invoked, _id, _action, _args, _opts}
  end

  test "the card and its record wait as long as the action's deadline, not 60 seconds", ctx do
    clock = start_supervised!({Agent, fn -> 1_000 end}, id: :device_card_clock)
    pending = :"gate_device_clocked_#{System.unique_integer([:positive])}"

    start_supervised!({Pending, name: pending, clock: fn -> Agent.get(clock, & &1) end},
      id: :clocked_pending
    )

    execute(@command, chat(ctx, %{access_pending: pending}))

    assert_received {:approval, %{access_sensitive: id, card: :device, ttl_s: 120, provenance: _}}
    assert_received {:reply, {:approval_prompt, %{kind: :device, ttl_s: 120}}}

    Agent.update(clock, &(&1 + 90_000))
    assert {:ok, _outcome} = AccessGate.confirm(id, pending)
    assert_received {:device_action_invoked, "desk-mac-1", "run_command", _args, _opts}
  end

  test "the resumed request's same call reads the confirmed command's output, run once", ctx do
    execute(@command, chat(ctx))
    assert_received {:approval, %{access_sensitive: id}}
    assert {:ok, _owner_text} = AccessGate.confirm(id, ctx.pending)
    assert_received {:device_action_invoked, "desk-mac-1", "run_command", _args, _opts}

    assert {:ok, %{success: true, output: output} = result} = execute(@command, chat(ctx))
    refute Map.has_key?(result, :access_waiting)
    assert output == "Ran on your Studio Mac (exit 0):\n4.0G\tdu -sh ~/Downloads"
    refute_received {:device_action_invoked, _id, _action, _args, _opts}
    refute_received {:approval, _request}

    assert_received {:telemetry, [:fermix, :tool, :exec], _measurements,
                     %{access_gate: "already_confirmed", access_intent: ^id}}
  end

  test "a read grant waits for the owner on a card naming the desktop and the folder", ctx do
    grant = %{"action" => "grant_read", "path" => "~/Downloads", "device" => "Studio Mac"}

    assert {:ok, %{success: false, access_waiting: true}} = execute(grant, chat(ctx))
    refute_received {:device_action_invoked, _id, _action, _args, _opts}

    assert_received {:approval, %{access_sensitive: id, card: :device, ttl_s: 120}}
    assert_received {:reply, {:approval_prompt, %{kind: :device, text: text}}}
    assert text =~ "Let Fermix read this folder on your Studio Mac?"
    assert text =~ "Computer: Studio Mac"
    assert text =~ "Folder: ~/Downloads"

    assert {:ok, _outcome} = AccessGate.confirm(id, ctx.pending)
    assert_received {:device_action_invoked, "desk-mac-1", "grant_read", sent, opts}
    assert sent == %{"path" => "~/Downloads"}
    assert opts[:deadline_s] == 120
  end

  test "a job naming device_action is not refused for it at set-up", ctx do
    assert :ok = AccessGate.check_job_tools(["device_action"], chat(ctx))
  end
end
