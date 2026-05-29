defmodule FermixChannels.Gateway.Commands.SandboxTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Source
  alias FermixChannels.Gateway.Message
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

  test "confirmation rejects mismatched user and thread", %{root: root} do
    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1", "owner-2"],
      command_allowlist: ["owner-2"]
    )

    token = propose_grant(root, message("/grant path #{root}", user_id: "owner-1", thread_ts: "t1"))

    assert :ok = dispatch(message("/confirm #{token}", user_id: "owner-2", thread_ts: "t1"))
    assert_receive {:sandbox_reply, "Confirmation failed: :origin_mismatch"}

    refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
  end

  test "concurrent first proposals do not race ETS table creation", %{root: root} do
    tasks =
      for index <- 1..20 do
        Task.async(fn ->
          dispatch(message("/grant path #{root}/#{index}", user_id: "owner-1"))
        end)
      end

    assert Enum.all?(Task.await_many(tasks, 2_000), &(&1 == :ok))
  end

  test "usage mentions env and command update forms" do
    assert :ok = dispatch(message("/sandbox nope", user_id: "owner-1"))

    assert_receive {:sandbox_reply, usage}
    assert usage =~ "/sandbox env set"
    assert usage =~ "/sandbox commands enable"
    assert usage =~ "/confirm"
  end

  test "rejected mutations include a follow-up command" do
    assert :ok = dispatch(message("/grant path /", user_id: "owner-1"))

    assert_receive {:sandbox_reply, reply}
    assert reply =~ "Sandbox change rejected"
    assert reply =~ "/sandbox explain"
  end

  defp propose_grant(root, message) do
    assert :ok = dispatch(message)
    assert_receive {:sandbox_reply, confirm_text}
    assert confirm_text =~ "allowed_roots + #{PathPolicy.canonical_path(root)}"
    [token] = Regex.run(~r/\/confirm ([A-Z2-7]{8})/, confirm_text, capture: :all_but_first)
    token
  end

  defp dispatch(message) do
    Commands.dispatch(
      Commands.parse(message),
      reply_fn(),
      %{
        conversation_key: {"telegram", "chat-1", :root},
        authorization: build_authorization(message)
      }
    )
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
