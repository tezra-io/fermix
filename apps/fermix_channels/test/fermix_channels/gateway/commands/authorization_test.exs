defmodule FermixChannels.Gateway.Commands.AuthorizationTest do
  @moduledoc """
  FIX 0 unit boundary: `operator_only/3` admits ONLY `role: :operator`, while
  `owner_only/3` keeps its `command_allowlist` guest branch for /new, /compact.
  The two must diverge exactly on the allowlist guest.
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorization, as: Decision
  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixChannels.Gateway.Message

  setup do
    previous = Application.get_env(:fermix_channels, :telegram, [])

    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1", "guest-2"],
      command_allowlist: ["guest-2"]
    )

    on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous) end)
    :ok
  end

  describe "operator (owner) context" do
    test "is admitted by both gates" do
      {message, metadata, context} = build("owner-1", :operator)

      assert Authorization.owner_only(message, metadata, context) == :ok
      assert Authorization.operator_only(message, metadata, context) == :ok
    end
  end

  describe "command_allowlist guest context" do
    test "owner_only admits it (chat commands), operator_only refuses it" do
      {message, metadata, context} = build("guest-2", :guest)

      assert Authorization.owner_only(message, metadata, context) == :ok
      assert Authorization.operator_only(message, metadata, context) == {:error, :unauthorized}
    end
  end

  describe "guest NOT in command_allowlist" do
    test "both gates refuse it" do
      Application.put_env(:fermix_channels, :telegram,
        owner_user_id: "owner-1",
        allowed_user_ids: ["owner-1", "guest-2"],
        command_allowlist: []
      )

      {message, metadata, context} = build("guest-2", :guest)

      assert Authorization.owner_only(message, metadata, context) == {:error, :unauthorized}
      assert Authorization.operator_only(message, metadata, context) == {:error, :unauthorized}
    end
  end

  describe "missing authorization" do
    test "both gates refuse it" do
      {message, metadata, _context} = build("owner-1", :operator)

      assert Authorization.owner_only(message, metadata, %{}) == {:error, :unauthorized}
      assert Authorization.operator_only(message, metadata, %{}) == {:error, :unauthorized}
    end
  end

  # SIDE-V1: the local sockets' transport trust makes every same-user peer an
  # operator, but the daemon reads who is on the other end (`SocketPeer`). A
  # process it started, or one no terminal is attached to, is not the owner, so
  # the approval family refuses it through `in_person/1`; the role gates, which
  # every other owner command uses, answer by role alone.
  describe "who sent it (metadata.caller)" do
    test "in_person/1 refuses a process the daemon started or a detached one" do
      for caller <- [:daemon_descendant, :detached] do
        {_message, metadata, _context} = build_local("cli", caller)

        assert Authorization.in_person(metadata) == {:error, :unattended}
      end
    end

    test "in_person/1 admits a person's terminal or app, and a message with no caller" do
      for channel <- ["cli", "companion"] do
        {_message, metadata, _context} = build_local(channel, :independent)

        assert Authorization.in_person(metadata) == :ok
      end

      assert Authorization.in_person(%{user_id: "cli"}) == :ok
    end

    test "the role gates answer by role alone, whoever sent it" do
      for caller <- [:daemon_descendant, :detached, :independent] do
        {message, metadata, context} = build_local("cli", caller)

        assert Authorization.owner_only(message, metadata, context) == :ok
        assert Authorization.operator_only(message, metadata, context) == :ok
      end
    end
  end

  defp build_local(channel, caller) do
    metadata = %{user_id: channel, caller: caller}

    message =
      Message.new!(%{
        id: "msg-#{System.unique_integer([:positive])}",
        content: "/confirm ABC",
        sender: channel,
        channel: channel,
        chat_id: channel,
        reply_target: channel,
        metadata: metadata
      })

    {message, metadata, %{authorization: %Decision{role: :operator, trust: :operator}}}
  end

  defp build(user_id, role) do
    message =
      Message.new!(%{
        id: "msg-#{System.unique_integer([:positive])}",
        content: "/confirm ABC",
        sender: "alice",
        channel: "telegram",
        chat_id: "chat-1",
        reply_target: "chat-1",
        metadata: %{user_id: user_id}
      })

    metadata = %{user_id: user_id}
    context = %{authorization: %Decision{role: role, trust: role}}
    {message, metadata, context}
  end
end
