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
