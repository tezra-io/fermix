defmodule FermixCore.Capabilities.AccessGateComputerTest do
  # M97 §6.4: a command after outside content is decided with the facts of the
  # machine it runs on. A command on a Mac computer runs, whatever the server
  # is; every command on a Linux computer waits for the owner's confirm, and
  # the prompt names that computer. A call that runs here is decided as before.
  # The server's platform is injected (`:os_sandbox`), so the host the suite
  # runs on never decides; each test parks in its own `AccessGate.Pending`.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Computers.Computer
  alias FermixCore.Tools.Shell
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry
  alias FermixTestSupport.TelemetryCapture

  @token "TOKEN321"
  @linux_server [os: {:unix, :linux}, landlock: {:ok, 4}]
  @mac_server [os: {:unix, :darwin}]
  @command "make release"

  def run(args, context, test_pid) do
    send(test_pid, {:executed, args, context})
    ToolTelemetry.exec("shell", context, true, 0)
    {:ok, %{success: true, output: "ran", error: nil}}
  end

  setup do
    sid = "gate-computer-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: sid)

    registry = :"gate_computer_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, shell())
    pending = :"gate_computer_pending_#{System.unique_integer([:positive])}"
    start_supervised!({Pending, name: pending})

    %{sid: sid, registry: registry, pending: pending}
  end

  defp shell,
    do: %{Builtin.from_tool_module(Shell) | executor: {__MODULE__, :run, [self()]}}

  defp computer(name, platform),
    do: %Computer{
      device_id: "id-#{name}",
      name: name,
      platform: platform,
      connected: true,
      offers: [%{id: "shell", state: :on, sentence: nil, detail: "standard"}]
    }

  defp computers,
    do: [
      computer("studio Mac", :macos),
      computer("loft Linux", :linux),
      computer("spare box", nil)
    ]

  # An owner's chat turn that read a web page: the case the rule is for.
  defp tainted(ctx, server_os) do
    test_pid = self()

    %{
      source_trust: :operator,
      computer_use_origin: :interactive,
      session_id: ctx.sid,
      agent_name: "main",
      conversation_key: {"telegram", ctx.sid, :root},
      chat_type: "private",
      capability_registry: ctx.registry,
      access_pending: ctx.pending,
      os_sandbox: server_os,
      outside_sources: MapSet.new([{:tool, "web_fetch"}]),
      computers: computers(),
      reply_fn: fn part -> send(test_pid, {:reply, part}) end,
      approval_fn: fn request ->
        send(test_pid, {:approval, request})
        {:ok, @token, :new}
      end
    }
  end

  defp exec_metadata do
    assert_receive {:telemetry, [:fermix, :tool, :exec], _measure, metadata}
    refute_received {:telemetry, [:fermix, :tool, :exec], _measure, _more}
    metadata
  end

  test "a command on a Mac computer runs after outside content, even from a Linux server", ctx do
    args = %{"command" => @command, "computer" => "studio Mac"}

    assert {:ok, %{success: true}} =
             Capability.execute(shell(), args, tainted(ctx, @linux_server))

    assert_received {:executed, %{"command" => @command} = run_args,
                     %{computer: %Computer{name: "studio Mac"}}}

    refute Map.has_key?(run_args, "computer")
    refute_received {:approval, _request}
    refute Map.has_key?(exec_metadata(), :access_gate)
  end

  test "a command on a Linux computer waits for the owner, even from a Mac server", ctx do
    args = %{"command" => @command, "working_dir" => "/srv/loft/site", "computer" => "loft Linux"}

    assert {:ok, %{success: false, access_waiting: true}} =
             Capability.execute(shell(), args, tainted(ctx, @mac_server))

    refute_received {:executed, _args, _context}
    assert_received {:approval, _request}
    assert_received {:reply, {:approval_prompt, prompt, @token}}

    assert prompt =~ "It runs a command on loft Linux, which Fermix cannot sandbox there."
    assert prompt =~ "Command: #{@command}"
    assert prompt =~ "Computer: loft Linux"
    assert prompt =~ "Folder: /srv/loft/site"
    assert exec_metadata().access_gate == "held_this_chat"
  end

  test "a computer whose system the home does not know is not taken to hold commands", ctx do
    args = %{"command" => @command, "computer" => "spare box"}

    assert {:ok, %{access_waiting: true}} =
             Capability.execute(shell(), args, tainted(ctx, @mac_server))

    refute_received {:executed, _args, _context}
  end

  test "the server's own folder is never shown for a command on a computer", ctx do
    context = Map.put(tainted(ctx, @mac_server), :cwd, "/home/owner/server-project")
    args = %{"command" => @command, "computer" => "loft Linux"}

    assert {:ok, %{access_waiting: true}} = Capability.execute(shell(), args, context)
    assert_received {:reply, {:approval_prompt, prompt, @token}}
    refute prompt =~ "server-project"
  end

  test "a command that runs here is decided by this server's system, as before", ctx do
    args = %{"command" => @command}

    assert {:ok, %{success: true}} = Capability.execute(shell(), args, tainted(ctx, @mac_server))
    assert_received {:executed, _args, %{computer: :here}}

    assert {:ok, %{access_waiting: true}} =
             Capability.execute(shell(), args, tainted(ctx, @linux_server))
  end
end
