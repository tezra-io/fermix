defmodule FermixChannels.Gateway.Commands.SandboxTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Source
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.PathPolicy

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
