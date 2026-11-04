defmodule FermixChannels.Gateway.Commands.SandboxTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Commands.Sandbox
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Source
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Proposals
  alias FermixCore.Cues.Watchers
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.PathPolicy
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.MandateFixtures

  @bare_owner "owner-bare"

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("channel-sandbox-command")
    root = Path.join(home, "project")
    File.mkdir_p!(root)

    previous_home = System.get_env("FERMIX_HOME")
    previous_sandbox = Application.get_env(:fermix_core, :sandbox)
    previous_telegram = Application.get_env(:fermix_channels, :telegram, [])

    System.put_env("FERMIX_HOME", home)
    Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")

    Application.put_env(
      :fermix_core,
      :sandbox,
      SandboxConfig.normalize(
        home: home,
        mode: :strict,
        workspace_root: Path.join(home, "workspace")
      )
    )

    on_exit(fn ->
      restore_env("FERMIX_HOME", previous_home)
      restore_sandbox(previous_sandbox)
      Application.put_env(:fermix_channels, :telegram, previous_telegram)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{root: root}
  end

  test "confirmation tokens are single-use", %{root: root} do
    token = propose_grant(root, message("/grant path #{root}", user_id: "owner-1"))

    assert :ok = dispatch(message("/confirm #{token}", user_id: "owner-1"))
    assert_receive {:sandbox_reply, "Sandbox updated." <> _rest}

    assert :ok = dispatch(message("/confirm #{token}", user_id: "owner-1"))
    assert_receive {:sandbox_reply, "Confirmation failed: :unknown_token"}
  end

  test "deny discards a pending grant without applying it", %{root: root} do
    token = propose_grant(root, message("/grant path #{root}", user_id: "owner-1"))

    assert :ok = dispatch(message("/deny #{token}", user_id: "owner-1"))

    assert_receive {:sandbox_reply, "Sandbox change denied — the pending grant was discarded."}

    refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots

    assert :ok = dispatch(message("/confirm #{token}", user_id: "owner-1"))
    assert_receive {:sandbox_reply, "Confirmation failed: :unknown_token"}
  end

  test "successful approve and deny report resolution without exposing it on failures", %{
    root: root
  } do
    notify = fn resolution ->
      send(self(), {:approval_resolution, resolution})
      :ok
    end

    approved = propose_grant(root, message("/grant path #{root}", user_id: "owner-1"))

    assert :ok =
             dispatch_with_context(
               message("/confirm #{approved}", user_id: "owner-1"),
               approval_resolution_fn: notify
             )

    assert_receive {:approval_resolution, %{kind: :sandbox, token: ^approved, outcome: :approved}}
    assert_receive {:sandbox_reply, "Sandbox updated." <> _rest}

    assert :ok =
             dispatch_with_context(
               message("/confirm #{approved}", user_id: "owner-1"),
               approval_resolution_fn: notify
             )

    refute_receive {:approval_resolution, _resolution}
    assert_receive {:sandbox_reply, "Confirmation failed: :unknown_token"}

    denied_root = root <> "-denied"
    File.mkdir_p!(denied_root)
    denied = propose_grant(denied_root, message("/grant path #{denied_root}", user_id: "owner-1"))

    assert :ok =
             dispatch_with_context(
               message("/deny #{denied}", user_id: "owner-1"),
               approval_resolution_fn: notify
             )

    assert_receive {:approval_resolution, %{kind: :sandbox, token: ^denied, outcome: :denied}}
    assert_receive {:sandbox_reply, "Sandbox change denied" <> _rest}
  end

  test "wrong-origin deny does not consume the owner's token", %{root: root} do
    token =
      propose_grant(root, message("/grant path #{root}", user_id: "owner-1", thread_ts: "t1"))

    assert :ok = dispatch(message("/deny #{token}", user_id: "owner-1", thread_ts: "t2"))
    assert_receive {:sandbox_reply, "Denial failed: :origin_mismatch"}

    assert :ok = dispatch(message("/deny #{token}", user_id: "owner-1", thread_ts: "t1"))

    assert_receive {:sandbox_reply, "Sandbox change denied — the pending grant was discarded."}
  end

  test "confirmation rejects an owner confirming from a mismatched thread", %{root: root} do
    token =
      propose_grant(root, message("/grant path #{root}", user_id: "owner-1", thread_ts: "t1"))

    assert :ok = dispatch(message("/confirm #{token}", user_id: "owner-1", thread_ts: "t2"))
    assert_receive {:sandbox_reply, "Confirmation failed: :origin_mismatch"}

    refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
  end

  # FIX 0: the command_allowlist admits a trusted guest for /new, /compact — it
  # must NOT reach operator-grade sandbox mutation. A guest's own /grant would
  # otherwise bind the pending record to their origin and let them self-approve.
  test "a command_allowlist guest cannot propose a directory grant", %{root: root} do
    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1", "owner-2"],
      command_allowlist: ["owner-2"]
    )

    assert {:error, :unauthorized} = dispatch(message("/grant path #{root}", user_id: "owner-2"))
    assert_receive {:sandbox_reply, "This command requires owner permissions."}
    refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
  end

  test "a command_allowlist guest cannot revoke a root", %{root: root} do
    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1", "owner-2"],
      command_allowlist: ["owner-2"]
    )

    assert {:error, :unauthorized} = dispatch(message("/revoke path #{root}", user_id: "owner-2"))
    assert_receive {:sandbox_reply, "This command requires owner permissions."}
  end

  test "a command_allowlist guest cannot confirm an owner's grant, and the token survives",
       %{root: root} do
    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1", "owner-2"],
      command_allowlist: ["owner-2"]
    )

    token = propose_grant(root, message("/grant path #{root}", user_id: "owner-1"))

    assert {:error, :unauthorized} = dispatch(message("/confirm #{token}", user_id: "owner-2"))
    assert_receive {:sandbox_reply, "This command requires owner permissions."}
    refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots

    # The guest's rejected confirm never touched the owner's single-use token.
    assert :ok = dispatch(message("/confirm #{token}", user_id: "owner-1"))
    assert_receive {:sandbox_reply, "Sandbox updated." <> _rest}
    assert PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
  end

  # FIX 1: a wrong-origin /confirm must peek → validate → reject WITHOUT the
  # single-use take, so it never burns the owner's live token.
  test "a wrong-origin confirm does not consume the owner's token", %{root: root} do
    token =
      propose_grant(root, message("/grant path #{root}", user_id: "owner-1", thread_ts: "t1"))

    assert :ok = dispatch(message("/confirm #{token}", user_id: "owner-1", thread_ts: "t2"))
    assert_receive {:sandbox_reply, "Confirmation failed: :origin_mismatch"}
    refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots

    # The token survived the rejected attempt — the correct origin still succeeds.
    assert :ok = dispatch(message("/confirm #{token}", user_id: "owner-1", thread_ts: "t1"))
    assert_receive {:sandbox_reply, "Sandbox updated." <> _rest}
    assert PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
  end

  # FIX 1 race: peek-then-take is not atomic, but the final take is the sole
  # single-use authority. Under concurrent valid confirms exactly one wins the
  # atomic take; the losers see the token already consumed, never a false success.
  test "concurrent valid confirms consume the token exactly once", %{root: root} do
    token = propose_grant(root, message("/grant path #{root}", user_id: "owner-1"))
    collector = self()

    reply = fn
      {:text, text} -> send(collector, {:race_reply, text})
      text -> send(collector, {:race_reply, text})
    end

    for _ <- 1..10 do
      Task.async(fn -> dispatch_with(message("/confirm #{token}", user_id: "owner-1"), reply) end)
    end
    |> Task.await_many(:infinity)

    results = for _ <- 1..10, do: race_reply()
    updated = Enum.count(results, &String.starts_with?(&1, "Sandbox updated."))

    assert updated == 1
    assert PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
  end

  # Deliberately no wall-clock budget on the await: the property is "every
  # concurrent first proposal succeeds", not "they finish in N ms". A proposal
  # canonicalizes ~25 candidate paths and `PathPolicy.canonical_path/1` lists
  # every ancestor directory of each, so the cost tracks how many entries sit in
  # this machine's `$TMPDIR` (where the sandbox home lives) and grows as that
  # dir fills up — a deadline here measures the host, not the code. ExUnit's
  # per-test timeout is the backstop for a genuine hang.
  test "concurrent first proposals do not race ETS table creation", %{root: root} do
    tasks =
      for index <- 1..20 do
        Task.async(fn ->
          dispatch(message("/grant path #{root}/#{index}", user_id: "owner-1"))
        end)
      end

    assert Enum.all?(Task.await_many(tasks, :infinity), &(&1 == :ok))
  end

  test "explain annotates effective roots with granted vs mode provenance", %{root: root} do
    home = Path.dirname(root)

    Application.put_env(
      :fermix_core,
      :sandbox,
      SandboxConfig.normalize(
        home: home,
        os_home: home,
        mode: :strict,
        workspace_root: Path.join(home, "workspace"),
        allowed_roots: [root]
      )
    )

    assert :ok = dispatch(message("/sandbox explain", user_id: "owner-1"))

    assert_receive {:sandbox_reply, reply}
    assert reply =~ "mode: strict"
    assert reply =~ "effective roots:"
    assert reply =~ "- #{PathPolicy.canonical_path(root)} (granted)"
    assert reply =~ "- #{PathPolicy.canonical_path(Path.join(home, "workspace"))} (mode)"
  end

  test "usage mentions env and command update forms" do
    assert :ok = dispatch(message("/sandbox nope", user_id: "owner-1"))

    assert_receive {:sandbox_reply, usage}
    assert usage =~ "/sandbox env set"
    assert usage =~ "/sandbox commands enable"
    assert usage =~ "/confirm"
    assert usage =~ "/deny"
  end

  test "rejected mutations include a follow-up command" do
    assert :ok = dispatch(message("/grant path /", user_id: "owner-1"))

    assert_receive {:sandbox_reply, reply}
    assert reply =~ "Sandbox change rejected"
    assert reply =~ "/sandbox explain"
  end

  # M60 §10.9: a mandate proposal's token goes to core, with the message's
  # origin; core answers only the owner's DM it sent the proposal to (C50).
  describe "a mandate proposal's token" do
    setup do
      proposal_setup()
    end

    test "/confirm from the owner's DM runs the recorded call and replies with core's words",
         ctx do
      assert :ok = dispatch_proposal(dm("/confirm #{ctx.token}"), ctx)
      assert_receive {:sandbox_reply, "Confirmed. github_create_issue ran:\n" <> framed}
      assert framed =~ ~s(<untrusted_tool_result source="github_create_issue">)
      assert_receive {:executed, "github_create_issue", _args, %{access_gate: "confirmed"}}

      assert :ok = dispatch_proposal(dm("/confirm #{ctx.token}"), ctx)
      assert_receive {:sandbox_reply, "That call was already confirmed; it runs at most once."}
      refute_received {:executed, _tool, _args, _context}
    end

    test "/confirm from a group chat is refused, and the token still works from the DM", ctx do
      group = message("/confirm #{ctx.token}", user_id: "owner-1")
      assert :ok = dispatch_proposal(group, ctx)
      assert_receive {:sandbox_reply, "Confirm it from the chat Fermix sent it to; nothing ran."}
      refute_received {:executed, _tool, _args, _context}

      assert :ok = dispatch_proposal(dm("/confirm #{ctx.token}"), ctx)
      assert_receive {:sandbox_reply, "Confirmed. " <> _result}
    end

    test "/confirm from anyone but the owner is refused before core sees it", ctx do
      stranger = %{dm("/confirm #{ctx.token}") | metadata: %{user_id: "stranger"}}
      assert {:error, :unauthorized} = dispatch_proposal(stranger, ctx)
      assert_receive {:sandbox_reply, "This command requires owner permissions."}
      refute_received {:executed, _tool, _args, _context}
    end

    test "/deny settles the proposal and nothing runs", ctx do
      assert :ok = dispatch_proposal(dm("/deny #{ctx.token}"), ctx)
      assert_receive {:sandbox_reply, "Denied. github_create_issue will not run."}

      assert :ok = dispatch_proposal(dm("/confirm #{ctx.token}"), ctx)
      assert_receive {:sandbox_reply, "That call was already denied."}
      refute_received {:executed, _tool, _args, _context}
    end

    # M60_WATCHER_CODING_RUNS.md §6.2: a tap on a watcher's card is answered
    # on the card, which becomes the answer's line.
    test "a tap on the card is answered on the card", ctx do
      tap = %{
        dm("/deny #{ctx.token}")
        | metadata: %{user_id: "owner-1", approval_message_id: "55"}
      }

      assert :ok = dispatch_proposal(tap, ctx)

      assert_receive {:sandbox_reply,
                      {:approval_answer, "55", "Denied. github_create_issue will not run."}}
    end

    # The 2026-10-31 revision: Always allow is a follow-up's card's alone.
    test "/always on a mandate's proposal runs nothing, and the proposal still waits", ctx do
      assert :ok = dispatch_proposal(dm("/always #{ctx.token}"), ctx)

      assert_receive {:sandbox_reply, "Only a follow-up's card offers Always allow; nothing ran."}

      refute_received {:executed, _tool, _args, _context}

      assert :ok = dispatch_proposal(dm("/always"), ctx)

      assert_receive {:sandbox_reply,
                      "Nothing here offers Always allow: only a follow-up's card waiting in " <>
                        "this chat does."}

      assert :ok = dispatch_proposal(dm("/confirm #{ctx.token}"), ctx)
      assert_receive {:sandbox_reply, "Confirmed. github_create_issue ran:\n" <> _framed}
    end
  end

  # The 2026-10-31 revision of M60_WATCHER_CODING_RUNS.md: `/always`, by token
  # or bare for the one card waiting, runs a follow-up and lets its later items
  # run with no card, as the card's Always allow button does.
  describe "/always on a follow-up's card" do
    setup do
      follow_up_setup()
    end

    test "by its token, it starts the run and allows the follow-up", ctx do
      assert :ok = dispatch_proposal(dm("/always #{ctx.token}"), ctx)
      assert_receive {:sandbox_reply, line}
      assert line =~ ~s(Starting "Deploy check" for post-1's post · )
      assert line =~ "Always allowed: from now on it runs with no card."
      assert {:ok, true} = Watchers.always_allowed(ctx.watcher, repo: ctx.repo)
    end

    test "bare, it answers the one follow-up's card waiting, on the card a tap came from",
         ctx do
      tap = %{dm("/always") | metadata: %{user_id: "owner-1", approval_message_id: "57"}}
      assert :ok = dispatch_proposal(tap, ctx)
      assert_receive {:sandbox_reply, {:approval_answer, "57", "Starting " <> _line}}
      assert {:ok, true} = Watchers.always_allowed(ctx.watcher, repo: ctx.repo)

      assert :ok = dispatch_proposal(dm("/always"), ctx)

      assert_receive {:sandbox_reply,
                      "Nothing here offers Always allow: only a follow-up's card waiting in " <>
                        "this chat does."}
    end

    test "a token this store holds is not a card, and takes no Always allow", ctx do
      assert :ok = dispatch_proposal(dm("/always AB12CD34"), ctx)

      assert_receive {:sandbox_reply,
                      "Nothing here offers Always allow: only a follow-up's card waiting in " <>
                        "this chat does."}

      assert {:ok, false} = Watchers.always_allowed(ctx.watcher, repo: ctx.repo)
    end
  end

  # A watcher whose follow-up's card waits in owner-1's DM, sent with a token
  # the test holds.
  defp follow_up_setup do
    now = ~U[2026-10-31 09:00:00.000000Z]
    %{repo: repo} = CueFixtures.start_repo("gateway_always")
    registry = :"gateway_always_caps_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({CapabilityRegistry, name: registry}, id: registry))
    tool = "deploy_check"

    :ok =
      CapabilityRegistry.register(
        registry,
        Capability.new(%{
          name: tool,
          description: "a test tool",
          parameters: %{"type" => "object", "properties" => %{}},
          kind: :builtin,
          executor: {__MODULE__, :never, []},
          policy_class: :exec
        })
      )

    token = Proposals.new_token()
    owner = %{platform: "telegram", chat_id: "owner-1", user_id: "owner-1"}

    opts = [
      repo: repo,
      now: now,
      scheduler: nil,
      cues_config: [],
      capability_registry: registry,
      channel_ready?: fn :telegram -> true end,
      wake_scheduler: fn -> :ok end,
      proposal_listener: fn _event -> :ok end,
      notice: fn _watcher, _kind, _data -> :ok end,
      follow_up_sender: fn _card ->
        {:ok, Map.put(owner, :token_digest, Proposals.digest(token))}
      end
    ]

    params = %{
      name: "deploy-watch",
      filter: "none",
      daily_cap: 5,
      sources: ["releases"],
      follow_up: %{name: "Deploy check", prompt: "Run the deploy check.", allowed_tools: [tool]}
    }

    context = %{
      agent_name: "main",
      conversation_key: {"telegram", "owner-1", :root},
      session_id: "telegram:owner-1:root",
      source_trust: :operator,
      memory_agent_id: "main"
    }

    {:ok, %{watcher: watcher}} = Watchers.create(params, context, opts)
    item = CueFixtures.item!(%{item_id: "post-1", subject: "post-1", occurred_at: now}, now)

    {:ok, _results} =
      Ingest.accept(%{ref: "releases", daily_budget: 0}, [item],
        now: now,
        repo: repo,
        wake_scheduler: fn -> :ok end,
        wake_filters: fn -> :ok end
      )

    {:ok, [trigger]} = Repo.cues_call(CuesFollowUpSql, {:claim_offers, now, 10}, server: repo)
    :offered = FollowUps.offer(trigger, opts)
    %{token: token, watcher: watcher, repo: repo, opts: opts}
  end

  # M60_WATCHER_CODING_RUNS.md §6.2, §9: a bare `/confirm` or `/deny` answers
  # the one thing waiting in that chat, counting the access gate's parked
  # calls as well as cards; with more than one it lists them.
  describe "a bare /confirm or /deny" do
    # An owner no other test binds a confirmation to: a bare answer counts
    # every live record of its chat, and the store is the application's.
    setup do
      Application.put_env(:fermix_channels, :telegram, owner_user_id: @bare_owner)
      proposal_setup(@bare_owner)
    end

    test "answers the one card waiting in the owner's DM", ctx do
      assert :ok = dispatch_proposal(dm("/confirm", @bare_owner), ctx)
      assert_receive {:sandbox_reply, "Confirmed. github_create_issue ran:\n" <> _framed}
      assert_receive {:executed, "github_create_issue", _args, %{access_gate: "confirmed"}}

      assert :ok = dispatch_proposal(dm("/confirm", @bare_owner), ctx)
      assert_receive {:sandbox_reply, "Nothing is waiting for your answer here."}
    end

    test "a bare /deny skips it, and runs nothing", ctx do
      assert :ok = dispatch_proposal(dm("/deny", @bare_owner), ctx)
      assert_receive {:sandbox_reply, "Denied. github_create_issue will not run."}
      refute_received {:executed, _tool, _args, _context}
    end

    test "with a card and a parked call, it lists both with what answers each", ctx do
      origin = %{channel: "telegram", chat_id: @bare_owner, thread_ts: nil, user_id: @bare_owner}

      {:ok, parked, :new} =
        Sandbox.store_pending_grant(
          %{access_sensitive: "intent-bare-1"},
          Map.put(origin, :resume, nil)
        )

      on_exit(fn -> Confirmations.take(parked) end)

      assert :ok = dispatch_proposal(dm("/confirm", @bare_owner), ctx)
      assert_receive {:sandbox_reply, listing}
      assert listing =~ "Several things are waiting for your answer here:"
      assert [_whole, card_id] = Regex.run(~r{for release-watch\? /confirm (cpr_\w+)}, listing)
      assert listing =~ "A command waiting to be sent /confirm #{parked}"
      refute_received {:executed, _tool, _args, _context}
      assert {:ok, _record} = Confirmations.peek(parked)

      assert :ok = dispatch_proposal(dm("/confirm #{card_id}", @bare_owner), ctx)
      assert_receive {:sandbox_reply, "Confirmed. github_create_issue ran:\n" <> _framed}
    end

    test "a card's id answers only from the chat it went to", ctx do
      assert :ok = dispatch_proposal(dm("/deny", @bare_owner), ctx)
      assert_receive {:sandbox_reply, "Denied. " <> _rest}

      group = message("/confirm cpr_0123456789abcdef01234567", user_id: @bare_owner)
      assert :ok = dispatch_proposal(group, ctx)
      assert_receive {:sandbox_reply, "That card is not waiting in this chat; nothing ran."}
    end
  end

  # A claimed cue run under an approved approve-mode mandate whose owner is
  # Telegram user owner-1, proposing one call through the access gate.
  defp proposal_setup(owner \\ "owner-1") do
    fixture = MandateFixtures.cue_run("gateway_proposal")
    registry = :"gateway_proposal_caps_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({CapabilityRegistry, name: registry}, id: registry))
    :ok = CapabilityRegistry.register(registry, MandateFixtures.capability())
    test_pid = self()

    seams = [
      config: MandateFixtures.config("release-issues", fixture.job.id, %{"mode" => "approve"}),
      configured_owners: %{"telegram" => owner},
      capability_registry: registry,
      proposal_sender: fn _inbox, %{token: token} ->
        send(test_pid, {:proposal_token, token})
        :ok
      end
    ]

    context = MandateFixtures.context(fixture, "release-issues", seams)
    opts = context.cue_mandate_opts
    {:ok, _status} = Pins.approve("release-issues", "test", MandateFixtures.now(), opts)

    {:ok, %{success: false}} =
      Capability.execute(MandateFixtures.capability(), proposal_args(), context)

    assert_receive {:proposal_token, token}
    %{token: token, opts: Keyword.put(opts, :now, ~U[2026-10-10 12:05:00.000000Z])}
  end

  defp proposal_args, do: %{"owner" => "example-org", "repo" => "ops", "title" => "Phoenix 2.0"}

  defp dm(content, owner \\ "owner-1") do
    %{message(content, user_id: owner) | chat_id: owner, reply_target: owner}
  end

  defp dispatch_proposal(message, ctx),
    do: dispatch_with_context(message, cue_proposal_opts: ctx.opts)

  defp propose_grant(root, message) do
    assert :ok = dispatch(message)
    assert_receive {:sandbox_approval, %{kind: :sandbox, token: structured_token}}
    assert_receive {:sandbox_reply, confirm_text}
    assert confirm_text =~ "allowed_roots + #{PathPolicy.canonical_path(root)}"
    [token] = Regex.run(~r/\/confirm ([A-Z2-7]{8})/, confirm_text, capture: :all_but_first)
    assert structured_token == token
    token
  end

  defp dispatch(message), do: dispatch_with(message, reply_fn())

  defp dispatch_with(message, reply_fn) do
    dispatch_with_context(message, [], reply_fn)
  end

  defp dispatch_with_context(message, extras, reply_fn \\ nil) do
    reply_fn = reply_fn || reply_fn()

    Commands.dispatch(
      Commands.parse(message),
      reply_fn,
      Map.merge(
        %{
          conversation_key: {"telegram", "chat-1", :root},
          authorization: build_authorization(message)
        },
        Map.new(extras)
      )
    )
  end

  defp race_reply do
    receive do
      {:race_reply, text} -> text
    after
      2_000 -> flunk("no confirm reply within 2s")
    end
  end

  defp build_authorization(message) do
    case message |> Map.from_struct() |> Source.from_message() |> Authorizer.resolve() do
      {:ok, auth} -> auth
      {:error, _reason} -> nil
    end
  end

  defp message(content, opts) do
    Message.new!(%{
      id: "msg-#{System.unique_integer([:positive])}",
      content: content,
      sender: "alice",
      channel: "telegram",
      chat_id: "chat-1",
      thread_ts: Keyword.get(opts, :thread_ts),
      reply_target: "chat-1",
      metadata: %{user_id: Keyword.fetch!(opts, :user_id)}
    })
  end

  defp reply_fn do
    test_pid = self()

    fn
      {:approval_prompt, %{text: text} = spec} ->
        send(test_pid, {:sandbox_approval, spec})
        send(test_pid, {:sandbox_reply, text})
        :ok

      {:text, text} ->
        send(test_pid, {:sandbox_reply, text})
        :ok

      text ->
        send(test_pid, {:sandbox_reply, text})
        :ok
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_sandbox(nil), do: Application.delete_env(:fermix_core, :sandbox)
  defp restore_sandbox(value), do: Application.put_env(:fermix_core, :sandbox, value)
end
