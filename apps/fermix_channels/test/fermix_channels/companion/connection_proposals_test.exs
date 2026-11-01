defmodule FermixChannels.Companion.ConnectionProposalsTest do
  @moduledoc """
  M60 app surface §3.7 (D28), companion protocols 4 and 5, end to end over a
  real 0600 Unix socket: a mandate's proposal (stored by the real gate on a
  throwaway repo) reaches the owner's connection as its compact card
  (M60_WATCHER_CODING_RUNS.md §6.3), on either version, is answered from it
  by id and runs the recorded call exactly once; a second answer from any
  surface, an answer after expiry or after the chat's confirm, and one from a
  connection the daemon started run nothing; a waiting proposal survives a
  restart and follows the `server_hello`.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Companion.Proposals
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Companion.Protocol
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Proposals, as: CueProposals
  alias FermixCore.Cues.ProposalView
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.MandateFixtures, as: F
  alias FermixTestSupport.ParentProcess

  @name "release-issues"
  @args %{"owner" => "example-org", "repo" => "ops", "title" => "Phoenix 2.0"}
  @recorded Map.put(@args, "labels", ["cue"])
  # A line's arrival over the socket, and a confirmed call's run in its task,
  # on a loaded runner (the peer is placed from the process table first).
  @arrival_ms 10_000

  setup do
    unique = System.unique_integer([:positive])
    registry = :"companion_prop_registry_#{unique}"
    connections = :"companion_prop_sup_#{unique}"
    socket_path = Path.join(System.tmp_dir!(), "fermix-cprop-#{unique}.sock")
    on_exit(fn -> FermixTestSupport.SafeRm.rm(socket_path) end)

    start_supervised!({Registry, keys: :duplicate, name: registry})

    approvals =
      start_supervised!(
        {Approvals,
         name: nil,
         schedule: fn _message, _delay -> make_ref() end,
         announce: fn _profile, _card, _transport -> :ok end}
      )

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    {fixture, context} = proposing!(unique, registry)

    endpoint_opts = [
      name: :"companion_prop_endpoint_#{unique}",
      socket_path: socket_path,
      max_clients: 4,
      connection_supervisor: connections,
      connection_opts: [
        registry: registry,
        approvals: approvals,
        proposal_opts: context.cue_mandate_opts
      ]
    ]

    start_supervised!({Endpoint, endpoint_opts})

    %{
      fixture: fixture,
      context: context,
      socket_path: socket_path,
      endpoint_opts: endpoint_opts
    }
  end

  # A claimed cue run under an approved approve-mode mandate whose proposals
  # are announced to this test's companion registry.
  defp proposing!(unique, registry) do
    fixture = F.cue_run("cprop#{unique}")
    config = F.config(@name, fixture.job.id, %{"mode" => "approve"})
    caps = :"companion_prop_caps_#{unique}"
    start_supervised!(Supervisor.child_spec({CapabilityRegistry, name: caps}, id: caps))
    :ok = CapabilityRegistry.register(caps, F.capability())
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: :prop_tasks))

    context =
      F.context(fixture, @name,
        config: config,
        capability_registry: caps,
        task_supervisor: tasks,
        proposal_listener: &Proposals.announce(&1, registry)
      )

    assert {:ok, %{state: :approved}} =
             Pins.approve(@name, "test", F.now(), context.cue_mandate_opts)

    {fixture, context}
  end

  # --- reaching the owner -------------------------------------------------------------

  test "a stored proposal reaches the owner's connection as its compact card, on either version",
       ctx do
    owner = hello(ctx.socket_path, 6)
    old = hello(ctx.socket_path, 5)
    id = propose!(ctx)

    assert %{"type" => "proposal", "profile_id" => "main", "proposal" => card} = recv(owner)
    assert card["proposal_id"] == id
    assert card["state"] == "waiting"
    assert card["task"] == %{"job_id" => ctx.fixture.job.id, "name" => "release issues"}
    assert card["outside"]["args_text"] == Jason.encode!(@recorded, pretty: true)
    assert %{"name" => "title", "value" => "Phoenix 2.0"} in card["outside"]["args"]
    refute Map.has_key?(card, "follow_up")

    assert card["outside"]["cue"] == %{
             "type" => "release",
             "subject" => "phoenix",
             "text" => "Phoenix 2.0 is out."
           }

    refute Map.has_key?(card, "decided_at")

    assert :ok =
             Protocol.validate_server_payload("proposal", %{
               "profile_id" => "main",
               "proposal" => card
             })

    assert %{"type" => "proposal", "proposal" => ^card} = recv(old)
  end

  test "a waiting proposal survives a restart and follows the server_hello, oldest first", ctx do
    id = propose!(ctx)
    restart_repo!(ctx.fixture)

    owner = hello(ctx.socket_path, 6)
    assert %{"type" => "proposal", "proposal" => %{"proposal_id" => ^id}} = recv(owner)

    old = hello(ctx.socket_path, 5)
    assert %{"type" => "proposal", "proposal" => %{"proposal_id" => ^id}} = recv(old)
  end

  # M60_WATCHER_CODING_RUNS.md §6.2: a follow-up's card names no mandate,
  # tool or arguments, which a version 4 client required, so it needs version
  # 5; every version in the window reads it, and its end.
  test "a follow-up's card reaches the owner's connections on either version", ctx do
    owner = hello(ctx.socket_path, 6)
    old = hello(ctx.socket_path, 5)
    registry = ctx.endpoint_opts[:connection_opts][:registry]
    card = ProposalView.follow_up_card(follow_up_card(), [])

    assert :ok = Proposals.announce({:offered, card}, registry)

    assert %{"type" => "proposal", "proposal" => wire} = recv(owner)
    assert wire["proposal_id"] == "cft_1"
    assert wire["follow_up"]["asks"] == "run"
    assert wire["follow_up"]["offers_always_allow"] == true
    assert wire["follow_up"]["tools"] == ["shell"]
    refute Map.has_key?(wire, "mandate")
    refute Map.has_key?(wire["outside"], "args_text")
    assert %{"type" => "proposal", "proposal" => ^wire} = recv(old)

    resolved = %{
      proposal_id: "cft_1",
      state: "confirmed",
      result_status: nil,
      sentence: "Confirmed; the follow-up is starting.",
      result_text: nil
    }

    assert :ok = Proposals.announce({:resolved, resolved}, registry)

    for client <- [owner, old] do
      assert %{"type" => "proposal_resolved", "proposal_id" => "cft_1"} = recv(client)
    end
  end

  test "a connection the daemon started is never sent a proposal, and its answer runs nothing",
       ctx do
    id = propose!(ctx)
    restart_endpoint(ctx, daemon_os_pid: ParentProcess.os_pid())

    agent = hello(ctx.socket_path, 5)
    send_line(agent, answer("agent-1", id, "confirm"))

    assert recv(agent) == %{
             "type" => "error",
             "reason" => "request_failed",
             "message" =>
               "Only the owner can answer a proposal, from the Fermix app or a paired phone.",
             "client_msg_id" => "agent-1"
           }

    refute_receive {:executed, _tool, _args, _context}, 100
    assert [{^id, "waiting"}] = F.proposals(ctx.fixture.conn)
  end

  # M75: a device-role engine runs a retired copy of a moved home, so an owner's
  # answer from it is refused by name and the proposal stays as it was.
  test "a device-role engine refuses an answer by name and decides nothing", ctx do
    id = propose!(ctx)
    role = %{role: :device, primary: "vm.example.test"}
    restart_endpoint(ctx, request_opts: [engine_role: role])

    owner = hello(ctx.socket_path, 5)
    send_line(owner, answer("mac-device-1", id, "confirm"))

    assert next_after_cards(owner, 3) == %{
             "type" => "error",
             "reason" => "request_failed",
             "message" => "This engine runs in the device role; the primary is vm.example.test.",
             "client_msg_id" => "mac-device-1"
           }

    refute_receive {:executed, _tool, _args, _context}, 100
    assert [{^id, "waiting"}] = F.proposals(ctx.fixture.conn)
  end

  # --- answering ------------------------------------------------------------------------

  test "the owner's confirm runs the recorded call exactly once; a second answer runs nothing",
       ctx do
    id = propose!(ctx)
    token = token!()
    owner = hello(ctx.socket_path, 5)
    assert %{"type" => "proposal"} = recv(owner)

    send_line(owner, answer("mac-1", id, "confirm"))

    assert recv(owner) == %{
             "type" => "accepted",
             "client_msg_id" => "mac-1",
             "duplicate" => false
           }

    assert recv(owner) == %{
             "type" => "proposal_resolved",
             "profile_id" => "main",
             "proposal_id" => id,
             "state" => "confirmed",
             "result_status" => "ok",
             "sentence" => "Confirmed. github_create_issue ran.",
             "result_text" => ~s({"number":42})
           }

    assert_receive {:executed, "github_create_issue", @recorded, executed}, @arrival_ms
    assert executed.access_gate == "confirmed"

    # A second answer, from this socket, the management socket or the chat.
    send_line(owner, answer("mac-2", id, "deny"))

    assert recv(owner) == %{
             "type" => "error",
             "reason" => "request_failed",
             "message" => "That call was already confirmed; it runs at most once.",
             "client_msg_id" => "mac-2"
           }

    seams = ctx.context.cue_mandate_opts
    management = %{surface: :management, device_id: nil}

    assert {:error, "That call was already confirmed; it runs at most once."} =
             CueProposals.decide(id, :confirm, management, seams)

    assert {:error, "That call was already confirmed; it runs at most once."} =
             CueProposals.confirm(token, owner_origin(), seams)

    refute_receive {:executed, _tool, _args, _context}, 100
    assert [%{result_status: "ok"}] = F.call_rows(ctx.fixture.conn, ctx.fixture.run.id)
  end

  test "a denial runs nothing, and every owner connection hears it", ctx do
    id = propose!(ctx)
    owner = hello(ctx.socket_path, 5)
    watcher = hello(ctx.socket_path, 5)
    assert %{"type" => "proposal"} = recv(owner)
    assert %{"type" => "proposal"} = recv(watcher)

    send_line(owner, answer("mac-3", id, "deny"))
    assert %{"type" => "accepted", "client_msg_id" => "mac-3"} = recv(owner)

    denied = %{
      "type" => "proposal_resolved",
      "profile_id" => "main",
      "proposal_id" => id,
      "state" => "denied",
      "sentence" => "Denied. github_create_issue will not run."
    }

    assert recv(owner) == denied
    assert recv(watcher) == denied
    refute_receive {:executed, _tool, _args, _context}, 100
    assert [{^id, "denied"}] = F.proposals(ctx.fixture.conn)
  end

  test "an answer after the chat's confirm runs nothing; the chat's confirm is heard here", ctx do
    id = propose!(ctx)
    owner = hello(ctx.socket_path, 5)
    assert %{"type" => "proposal"} = recv(owner)

    assert {:ok, _reply} =
             CueProposals.confirm(token!(), owner_origin(), ctx.context.cue_mandate_opts)

    assert_received {:executed, _tool, _args, _context}

    assert %{"type" => "proposal_resolved", "state" => "confirmed", "proposal_id" => ^id} =
             recv(owner)

    send_line(owner, answer("mac-4", id, "confirm"))

    assert %{
             "type" => "error",
             "message" => "That call was already confirmed; it runs at most once.",
             "client_msg_id" => "mac-4"
           } = recv(owner)

    refute_receive {:executed, _tool, _args, _context}, 100
  end

  # The 2026-10-31 revision of M60_WATCHER_CODING_RUNS.md: `always_allow` is a
  # follow-up's card's answer; the wire takes it, and a mandate's card refuses it.
  test "always_allow on a mandate's proposal is refused by core, and it still waits", ctx do
    id = propose!(ctx)
    owner = hello(ctx.socket_path, 6)
    assert %{"type" => "proposal"} = recv(owner)

    send_line(owner, answer("mac-6", id, "always_allow"))

    assert recv(owner) == %{
             "type" => "error",
             "reason" => "request_failed",
             "message" => "Only a follow-up's card offers Always allow; nothing ran.",
             "client_msg_id" => "mac-6"
           }

    refute_receive {:executed, _tool, _args, _context}, 100
    assert [{^id, "waiting"}] = F.proposals(ctx.fixture.conn)
  end

  test "an answer after the proposal expired runs nothing", ctx do
    id = propose!(ctx)

    later =
      Keyword.put(ctx.context.cue_mandate_opts, :now, DateTime.add(F.now(), 31 * 60, :second))

    restart_endpoint(ctx, proposal_opts: later)

    owner = hello(ctx.socket_path, 5)
    send_line(owner, answer("mac-5", id, "confirm"))

    assert recv(owner) == %{
             "type" => "error",
             "reason" => "request_failed",
             "message" => "That proposal expired; nothing ran.",
             "client_msg_id" => "mac-5"
           }

    refute_receive {:executed, _tool, _args, _context}, 100
  end

  # --- helpers ------------------------------------------------------------------------

  # The model's call, proposed through the real gate; the id it stored.
  defp propose!(ctx) do
    assert {:ok, %{success: false, error: text}} =
             Capability.execute(F.capability(), @args, ctx.context)

    assert text =~ "Proposed to the owner"
    [{id, "waiting"}] = F.proposals(ctx.fixture.conn)
    id
  end

  defp token! do
    assert_received {:proposal, _inbox, _message, token}
    token
  end

  defp owner_origin, do: %{platform: "telegram", chat_id: F.owner_id(), user_id: F.owner_id()}

  defp answer(client_msg_id, proposal_id, decision) do
    %{
      "type" => "proposal_answer",
      "client_msg_id" => client_msg_id,
      "profile_id" => "main",
      "proposal_id" => proposal_id,
      "decision" => decision
    }
  end

  # The daemon's Repo again, on the same database: what a restart leaves.
  defp restart_repo!(fixture) do
    :ok = stop_supervised(fixture.repo)

    start_supervised!(
      Supervisor.child_spec(
        {Repo, name: fixture.repo, enabled: true, database_path: fixture.db_path},
        id: {:restarted, fixture.repo}
      )
    )
  end

  # The next line that is not a waiting proposal's card, which follows the
  # hello, reading at most `left` lines.
  defp next_after_cards(client, left) when left > 0 do
    case recv(client) do
      %{"type" => "proposal"} -> next_after_cards(client, left - 1)
      line -> line
    end
  end

  defp restart_endpoint(ctx, connection_opts) do
    stop_supervised!(Endpoint)

    ctx.endpoint_opts
    |> Keyword.update!(:connection_opts, &Keyword.merge(&1, connection_opts))
    |> then(&start_supervised!({Endpoint, &1}))
  end

  defp follow_up_card do
    %{
      trigger_id: "cft_1",
      state: "waiting",
      mode: "approve",
      reason: nil,
      created_at: ~U[2026-10-30 12:00:00Z],
      expires_at: ~U[2026-10-30 12:30:00Z],
      decided_at: nil,
      decided_from: nil,
      run_id: nil,
      watcher: %{id: "cwt_1", name: "codex-limits"},
      follow_up: %{
        job_id: "job_1",
        name: "Deploy check",
        instructions: "Run the deploy check script and report.",
        tools: ["shell"],
        delivery: %{mode: "origin", target: %{"platform" => "telegram", "chat_id" => "owner-1"}}
      },
      outside: %{
        source_ref: "releases",
        received_at: ~U[2026-10-30 11:59:00Z],
        occurred_at: nil,
        type: "release",
        subject: "kestrel",
        text: "Kestrel 2.4 is out.",
        reason: "a release"
      }
    }
  end

  defp hello(path, version) do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => version})
    assert %{"type" => "server_hello"} = recv(client)
    client
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        active: false,
        packet: :line,
        buffer: 128 * 1_024
      ])

    socket
  end

  defp send_line(socket, map), do: :ok = :gen_tcp.send(socket, Jason.encode!(map) <> "\n")

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, @arrival_ms)
    Jason.decode!(line)
  end
end
