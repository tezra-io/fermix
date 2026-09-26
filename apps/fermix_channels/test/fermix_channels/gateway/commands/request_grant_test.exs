defmodule FermixChannels.Gateway.Commands.RequestGrantTest do
  @moduledoc """
  The channels side of the grant-approval loop (SANDBOX_ACCESS_APPROVAL_FLOW §3):
  the `store_pending_grant/2` record builder + dedupe, and `/confirm` auto-resume
  for an agent-initiated record (chat re-ingest vs one-shot CLI).
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Commands.Sandbox, as: SandboxCommand
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Source
  alias FermixCore.Harness.Ledger
  alias FermixCore.Memory.Repo
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.PathPolicy

  # Captures the re-ingested agent message so the resume path can be asserted
  # without a live MainAgent. `handle_message/2` receives `agent_server` (the test
  # pid) as its second argument, so it reports straight back to the test.
  defmodule StubAgent do
    def handle_message(msg, server) do
      send(server, {:resumed, msg})
      :ok
    end
  end

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("channel-request-grant")
    root = Path.join(home, "project")
    File.mkdir_p!(root)

    previous_home = System.get_env("FERMIX_HOME")
    previous_sandbox = Application.get_env(:fermix_core, :sandbox)
    previous_telegram = Application.get_env(:fermix_channels, :telegram, [])

    System.put_env("FERMIX_HOME", home)

    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1", "owner-2"],
      command_allowlist: ["owner-2"]
    )

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

  describe "store_pending_grant/2" do
    test "builds an origin-bound, TTL'd record with a chat resume intent", %{root: root} do
      origin =
        chat_origin("owner-1",
          resume: %{content: "do it", reply_target: "chat-1", sender: "alice"}
        )

      assert {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)
      assert {:ok, record} = Confirmations.take(token)

      assert record.mutation == {:add_allowed_root, root}
      assert record.channel == "telegram"
      assert record.chat_id == "chat-1"
      assert record.thread_ts == nil
      assert record.user_id == "owner-1"
      assert record.resume == %{content: "do it", reply_target: "chat-1", sender: "alice"}
      refute Map.has_key?(record, :ingress_context)
      assert record.expires_at > System.monotonic_time(:millisecond)
    end

    test "a CLI-origin record carries no resume intent", %{root: root} do
      origin = %{channel: "cli", chat_id: "cli", thread_ts: nil, user_id: "cli", resume: nil}

      assert {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)
      assert {:ok, record} = Confirmations.take(token)
      assert record.resume == nil
    end

    test "dedupes a re-request for the same mutation + origin to the existing token", %{
      root: root
    } do
      origin =
        chat_origin("owner-1",
          resume: %{content: "do it", reply_target: "chat-1", sender: "alice"}
        )

      assert {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)
      assert {:ok, ^token, :existing} = SandboxCommand.store_pending_grant(request(root), origin)
    end

    test "a different origin gets its own token", %{root: root} do
      origin_a = chat_origin("owner-1", resume: nil)
      origin_b = chat_origin("owner-2", resume: nil)

      assert {:ok, token_a, :new} = SandboxCommand.store_pending_grant(request(root), origin_a)
      assert {:ok, token_b, :new} = SandboxCommand.store_pending_grant(request(root), origin_b)
      refute token_a == token_b
    end

    test "mobile grants from different authenticated devices do not dedupe", %{root: root} do
      origin =
        mobile_origin("device-1",
          resume: %{content: "do it", reply_target: "main", sender: "alice"}
        )

      other_device =
        mobile_origin("device-2",
          resume: %{content: "do it", reply_target: "main", sender: "alice"}
        )

      assert {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)

      assert {:ok, other_token, :new} =
               SandboxCommand.store_pending_grant(request(root), other_device)

      refute token == other_token
    end
  end

  describe "/confirm auto-resume" do
    test "an agent-created chat record persists the root and re-ingests the verbatim request",
         %{root: root} do
      origin =
        chat_origin("owner-1",
          resume: %{content: "finish the refactor", reply_target: "chat-1", sender: "alice"}
        )

      {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)

      assert :ok = confirm(token, "owner-1", agent_ctx())
      assert_receive {:sandbox_reply, reply}
      assert reply =~ "resuming your request"
      assert PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots

      assert_receive {:resumed, resumed}, 2_000
      assert resumed.content == "finish the refactor"
      assert resumed.channel == "telegram"
      assert resumed.chat_id == "chat-1"
      assert resumed.metadata.resumed_from_grant == token
      assert resumed.metadata.user_id == "owner-1"
    end

    test "a mobile grant resumes with its connection-authenticated ingress context", %{root: root} do
      origin =
        mobile_origin("device-1",
          resume: %{content: "finish on mobile", reply_target: "main", sender: "alice"}
        )

      {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)

      assert :ok = confirm_mobile(token, origin.ingress_context, agent_ctx())
      assert_receive {:sandbox_reply, reply}
      assert reply =~ "resuming your request"

      assert_receive {:resumed, resumed}, 2_000
      assert resumed.content == "finish on mobile"
      assert resumed.channel == "mobile"
      assert resumed.chat_id == "main"
      refute Map.has_key?(resumed.metadata, :ingress_context)
    end

    test "a CLI-origin record persists but never re-ingests; the owner re-runs", %{root: root} do
      origin = %{channel: "cli", chat_id: "cli", thread_ts: nil, user_id: "cli", resume: nil}
      {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)

      assert :ok = confirm_cli(token, agent_ctx())
      assert_receive {:sandbox_reply, reply}
      assert reply =~ "re-run your request"
      assert PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots

      refute_receive {:resumed, _}, 200
    end

    test "rejects a confirm from a command_allowlist guest and keeps the token", %{root: root} do
      # owner-2 is a command_allowlist guest (module setup). FIX 0: /confirm is
      # operator-only, so the guest is refused at authorization — before the
      # pending record is ever peeked — and the owner's token survives intact.
      origin =
        chat_origin("owner-1", resume: %{content: "x", reply_target: "chat-1", sender: "alice"})

      {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)

      assert {:error, :unauthorized} = confirm(token, "owner-2", agent_ctx())
      assert_receive {:sandbox_reply, "This command requires owner permissions."}
      refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
      refute_receive {:resumed, _}, 200

      # The owner can still confirm the untouched token and auto-resume.
      assert :ok = confirm(token, "owner-1", agent_ctx())
      assert_receive {:sandbox_reply, reply}
      assert reply =~ "resuming your request"
      assert PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
    end

    test "rejects an expired token", %{root: root} do
      token = "EXPIRED1"

      Confirmations.store(token, %{
        mutation: {:add_allowed_root, root},
        channel: "telegram",
        chat_id: "chat-1",
        thread_ts: nil,
        user_id: "owner-1",
        resume: %{content: "x", reply_target: "chat-1", sender: "alice"},
        expires_at: System.monotonic_time(:millisecond) - 1_000
      })

      assert :ok = confirm(token, "owner-1", agent_ctx())
      assert_receive {:sandbox_reply, "Confirmation failed: :expired"}
      refute_receive {:resumed, _}, 200
    end
  end

  # GAP3-1: a coding run changed vendor config that runs at the next harness
  # launch, so that launch asks the owner once. The acknowledgment rides the same
  # pending-record + `/confirm` + auto-resume path as a directory grant.
  describe "vendor-config acknowledgment" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-grant-harness-#{unique}.db")
      repo = :"grant_harness_repo_#{unique}"
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      end)

      %{repo: repo, run_id: seed_changed_run(repo)}
    end

    test "builds an origin-bound record for the run's acknowledgment", %{run_id: run_id} do
      origin = chat_origin("owner-1", resume: nil)

      assert {:ok, token, :new} = SandboxCommand.store_pending_grant(ack(run_id), origin)
      assert {:ok, ^token, :existing} = SandboxCommand.store_pending_grant(ack(run_id), origin)
      assert {:ok, record} = Confirmations.take(token)
      assert record.mutation == {:acknowledge_vendor_config, run_id}
    end

    test "/confirm clears the change and re-ingests the verbatim request", %{
      repo: repo,
      run_id: run_id
    } do
      origin =
        chat_origin("owner-1",
          resume: %{content: "now have Claude review it", reply_target: "chat-1", sender: "alice"}
        )

      {:ok, token, :new} = SandboxCommand.store_pending_grant(ack(run_id), origin)

      assert :ok = confirm(token, "owner-1", Map.put(agent_ctx(), :memory_repo, repo))
      assert_receive {:sandbox_reply, reply}
      assert reply =~ "resuming your request"
      refute reply =~ "Sandbox updated"

      assert {:ok, %{vendor_config_cleared_at: %DateTime{}}} = Ledger.get(run_id, server: repo)
      assert {:ok, []} = Ledger.unresolved_vendor_config(server: repo)

      assert_receive {:resumed, resumed}, 2_000
      assert resumed.content == "now have Claude review it"
      assert resumed.metadata.resumed_from_grant == token
    end

    test "/deny discards the prompt and leaves the change unresolved", %{
      repo: repo,
      run_id: run_id
    } do
      {:ok, token, :new} =
        SandboxCommand.store_pending_grant(ack(run_id), chat_origin("owner-1", resume: nil))

      message = telegram_message("/deny #{token}", "owner-1")
      assert :ok = dispatch(message, Map.put(agent_ctx(), :memory_repo, repo))
      assert_receive {:sandbox_reply, reply}
      refute reply =~ "Sandbox"
      assert reply =~ "revert or commit"

      assert {:ok, [%{id: ^run_id}]} = Ledger.unresolved_vendor_config(server: repo)
      refute_receive {:resumed, _}, 200
    end
  end

  # The inline "Approve" button synthesizes the same inbound message a typed
  # /confirm would, then funnels through the UNCHANGED confirm path. These tests
  # drive `Telegram.parse_update/1` on a real callback_query so the button and the
  # confirm invariants (persist, single-use, owner_only, auto-resume) are proven
  # against the same seams as the typed path — never ConfigMutation.persist direct.
  describe "inline Approve button (callback_query) → confirm" do
    setup do
      # A callback carries integer Telegram ids; make id 111 the owner so the tap
      # is authorized. Restored by the module setup's on_exit (previous_telegram).
      Application.put_env(:fermix_channels, :telegram,
        owner_user_id: "111",
        allowed_user_ids: ["111"],
        command_allowlist: []
      )

      :ok
    end

    test "a tap persists the grant, auto-resumes, and the token is single-use", %{root: root} do
      origin =
        callback_origin(resume: %{content: "finish it", reply_target: "123", sender: "alice"})

      {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)

      {:ok, [tap]} = Telegram.parse_update(callback_update(token, 111))
      assert tap.content == "/confirm #{token}"

      assert :ok = dispatch(tap, agent_ctx())
      assert_receive {:sandbox_reply, reply}
      assert reply =~ "resuming your request"
      assert PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots

      assert_receive {:resumed, resumed}, 2_000
      assert resumed.content == "finish it"
      assert resumed.metadata.resumed_from_grant == token

      # Single-use: a second tap of the same button finds no pending record.
      {:ok, [again]} = Telegram.parse_update(callback_update(token, 111))
      assert :ok = dispatch(again, agent_ctx())
      assert_receive {:sandbox_reply, "Confirmation failed: :unknown_token"}
    end

    test "a tap from a non-owner is refused and never persists", %{root: root} do
      origin = callback_origin(resume: %{content: "x", reply_target: "123", sender: "alice"})
      {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)

      {:ok, [tap]} = Telegram.parse_update(callback_update(token, 222))

      assert {:error, :unauthorized} = dispatch(tap, agent_ctx())
      assert_receive {:sandbox_reply, "This command requires owner permissions."}
      refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
      refute_receive {:resumed, _}, 200
    end
  end

  defp callback_origin(opts) do
    %{
      channel: "telegram",
      chat_id: "123",
      thread_ts: nil,
      user_id: "111",
      resume: Keyword.fetch!(opts, :resume)
    }
  end

  defp callback_update(token, from_id) do
    %{
      "callback_query" => %{
        "id" => "cbq-#{System.unique_integer([:positive])}",
        "data" => "grant:#{token}",
        "from" => %{"id" => from_id, "username" => "alice"},
        "message" => %{"message_id" => 55, "chat" => %{"id" => 123, "type" => "private"}}
      }
    }
  end

  defp request(root),
    do: %{path: root, reason: "the task needs it", diff: "allowed_roots + #{root}"}

  defp ack(run_id), do: %{acknowledge_vendor_config: run_id}

  # A finished coding run whose child planted Claude's local settings.
  defp seed_changed_run(repo) do
    change = %{"before" => nil, "after" => "sha256:bb", "commit_clears" => true}

    {:ok, run} =
      Ledger.admit(
        %{
          vendor: "codex",
          rail: "local",
          status: "starting",
          cwd: "/repo",
          worktree_root: "/repo",
          lock_roots: ["/repo"],
          artifacts_dir: "/repo/.fermix/artifacts/run",
          origin_kind: "chat",
          origin_session_id: "telegram:chat-1:root",
          delivery_mode: "origin"
        },
        server: repo
      )

    changes = %{"/repo" => %{".claude/settings.local.json" => change}}

    {:ok, _row} =
      Ledger.terminalize(run.id, "completed", %{vendor_config_changes: changes}, server: repo)

    run.id
  end

  defp chat_origin(user_id, opts) do
    %{
      channel: "telegram",
      chat_id: "chat-1",
      thread_ts: nil,
      user_id: user_id,
      resume: Keyword.fetch!(opts, :resume)
    }
  end

  defp mobile_origin(device_id, opts) do
    %{
      channel: "mobile",
      chat_id: "main",
      thread_ts: nil,
      user_id: nil,
      resume: Keyword.fetch!(opts, :resume),
      ingress_context: %{
        transport: :mobile,
        authenticated_device_id: device_id
      }
    }
  end

  defp agent_ctx do
    %{
      conversation_key: {"telegram", "chat-1", :root},
      agent: StubAgent,
      agent_server: self()
    }
  end

  defp confirm(token, user_id, context) do
    dispatch(telegram_message("/confirm #{token}", user_id), context)
  end

  defp confirm_cli(token, context) do
    dispatch(cli_message("/confirm #{token}"), context)
  end

  defp confirm_mobile(token, ingress_context, context) do
    message = mobile_message("/confirm #{token}")

    Commands.dispatch(
      Commands.parse(message),
      reply_fn(),
      context
      |> Map.put(:authorization, build_authorization(message, ingress_context))
    )
  end

  defp dispatch(message, context) do
    Commands.dispatch(
      Commands.parse(message),
      reply_fn(),
      Map.put(context, :authorization, build_authorization(message))
    )
  end

  defp build_authorization(message) do
    build_authorization(message, nil)
  end

  defp build_authorization(message, ingress_context) do
    case message
         |> Map.from_struct()
         |> Source.from_message(ingress_context)
         |> Authorizer.resolve() do
      {:ok, auth} -> auth
      {:error, _reason} -> nil
    end
  end

  defp telegram_message(content, user_id) do
    Message.new!(%{
      id: "msg-#{System.unique_integer([:positive])}",
      content: content,
      sender: "alice",
      channel: "telegram",
      chat_id: "chat-1",
      reply_target: "chat-1",
      metadata: %{user_id: user_id}
    })
  end

  defp cli_message(content) do
    Message.new!(%{
      id: "msg-#{System.unique_integer([:positive])}",
      content: content,
      sender: "cli",
      channel: "cli",
      chat_id: "cli",
      reply_target: "cli",
      metadata: %{user_id: "cli"}
    })
  end

  defp mobile_message(content) do
    Message.new!(%{
      id: "msg-#{System.unique_integer([:positive])}",
      content: content,
      sender: "mobile",
      channel: "mobile",
      chat_id: "main",
      reply_target: "main",
      metadata: %{}
    })
  end

  defp reply_fn do
    test_pid = self()

    fn
      {:text, text} ->
        send(test_pid, {:sandbox_reply, text})
        :ok

      other ->
        send(test_pid, {:sandbox_reply, other})
        :ok
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_sandbox(nil), do: Application.delete_env(:fermix_core, :sandbox)
  defp restore_sandbox(value), do: Application.put_env(:fermix_core, :sandbox, value)
end
