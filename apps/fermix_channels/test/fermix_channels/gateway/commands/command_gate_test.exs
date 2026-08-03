defmodule FermixChannels.Gateway.Commands.CommandGateTest do
  @moduledoc """
  Whole-surface command gate invariant: every trigger the registry exposes is
  classified as either strictly operator-only (daemon-global or durable state)
  or reachable by a `command_allowlist` guest (conversation-scoped lifecycle).
  Triggers are enumerated from `Registry.list/0`, so a command or alias added
  later either joins one of the two lists or fails `every registered trigger is
  classified` — it cannot silently inherit the guest branch by copy-paste.
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorization, as: Decision
  alias FermixChannels.Gateway.Commands.Registry
  alias FermixChannels.Gateway.Message

  # Daemon-global or durable-state triggers. `/soul` rewrites SOUL.md on disk
  # and its confirmation token is bound to the requester's own conversation, so
  # an allowlisted guest could otherwise self-approve their own persona edit;
  # `/skills` writes the operator's skill inventory and approves curation
  # proposals built from the owner's private history; `/stop` fans out across
  # every conversation and channel; `/background` spends the owner's provider
  # budget outside the single-flight queue; the sandbox mutation subcommands
  # were already strict.
  @operator_only ~w(soul skills stop background bg grant revoke confirm)

  # Conversation-scoped lifecycle (plus the two unauthenticated informational
  # commands): this is what the `command_allowlist` guest branch exists for.
  @guest_reachable ~w(compact new clear help whoami sandbox pause resume tasks ultra)

  setup do
    previous_channel = Application.get_env(:fermix_channels, :telegram, [])
    previous_commands = Application.fetch_env(:fermix_channels, :commands)

    # Enumerate the SHIPPED registry: other suites put their own command list in
    # this key, so establish the default here rather than reading whatever an
    # earlier module left behind.
    Application.delete_env(:fermix_channels, :commands)

    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1", "guest-2"],
      command_allowlist: ["guest-2"]
    )

    on_exit(fn ->
      Application.put_env(:fermix_channels, :telegram, previous_channel)
      restore_commands(previous_commands)
    end)

    :ok
  end

  test "every registered trigger is classified" do
    assert Enum.sort(triggers()) == Enum.sort(@operator_only ++ @guest_reachable)
  end

  test "a command_allowlist guest is refused every operator-only trigger" do
    for trigger <- @operator_only do
      assert authorize(trigger, "guest-2", :guest) == {:error, :unauthorized},
             "/#{trigger} must not be reachable through command_allowlist"
    end
  end

  test "a command_allowlist guest keeps the conversation-scoped triggers" do
    for trigger <- @guest_reachable do
      assert authorize(trigger, "guest-2", :guest) == :ok,
             "/#{trigger} must stay reachable for a command_allowlist guest"
    end
  end

  test "a guest outside the allowlist reaches only the unauthenticated commands" do
    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1", "guest-2"],
      command_allowlist: []
    )

    for trigger <- triggers() -- ~w(help whoami) do
      assert authorize(trigger, "guest-2", :guest) == {:error, :unauthorized},
             "/#{trigger} must be refused without a command_allowlist entry"
    end
  end

  test "the owner keeps every trigger" do
    for trigger <- triggers() do
      assert authorize(trigger, "owner-1", :operator) == :ok,
             "/#{trigger} must stay available to the operator"
    end
  end

  defp triggers do
    Enum.flat_map(Registry.list(), fn command -> [command.name() | command.aliases()] end)
  end

  defp authorize(trigger, user_id, role) do
    {:ok, handler} = Registry.lookup(trigger)
    metadata = %{user_id: user_id, command_name: trigger}
    context = %{authorization: %Decision{role: role, trust: role}}

    handler.authorize(message(trigger, metadata), metadata, context)
  end

  defp message(trigger, metadata) do
    Message.new!(%{
      id: "msg-#{System.unique_integer([:positive])}",
      content: "/#{trigger}",
      sender: "alice",
      channel: "telegram",
      chat_id: "chat-1",
      reply_target: "chat-1",
      metadata: metadata
    })
  end

  defp restore_commands({:ok, value}), do: Application.put_env(:fermix_channels, :commands, value)
  defp restore_commands(:error), do: Application.delete_env(:fermix_channels, :commands)
end
