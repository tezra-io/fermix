defmodule FermixChannels.Ingress.AuthorizerTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Ingress.Authorization
  alias FermixChannels.Ingress.Authorizer
  alias FermixChannels.Ingress.Source

  setup do
    previous = Application.get_env(:fermix_channels, :telegram, [])

    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1", "helper-1"]
    )

    on_exit(fn ->
      Application.put_env(:fermix_channels, :telegram, previous)
    end)

    :ok
  end

  describe "resolve/1" do
    test "configured owner of a remote channel resolves to :operator" do
      source = %Source{channel: "telegram", channel_key: :telegram, sender_id: "owner-1"}

      assert {:ok, %Authorization{role: :operator, trust: :operator}} =
               Authorizer.resolve(source)
    end

    test "allowed non-owner resolves to :guest (read-only)" do
      source = %Source{channel: "telegram", channel_key: :telegram, sender_id: "helper-1"}

      assert {:ok, %Authorization{role: :guest, trust: :guest}} =
               Authorizer.resolve(source)
    end

    test "unknown sender is denied" do
      source = %Source{channel: "telegram", channel_key: :telegram, sender_id: "stranger"}

      assert {:error, :unauthorized} = Authorizer.resolve(source)
    end

    test "missing sender id on a remote channel is denied" do
      source = %Source{channel: "telegram", channel_key: :telegram, sender_id: nil}

      assert {:error, :unauthorized} = Authorizer.resolve(source)
    end

    test "local cli channel resolves to :operator" do
      source = %Source{channel: "cli", channel_key: nil}

      assert {:ok, %Authorization{role: :operator, trust: :operator}} =
               Authorizer.resolve(source)
    end

    test "local daemon channel resolves to :operator" do
      source = %Source{channel: "daemon", channel_key: nil}

      assert {:ok, %Authorization{role: :operator, trust: :operator}} =
               Authorizer.resolve(source)
    end

    test "unknown remote channel is rejected with :unknown_channel" do
      source = %Source{channel: "matrix", channel_key: nil}

      assert {:error, :unknown_channel} = Authorizer.resolve(source)
    end

    test "a sole allowed user without explicit owner_user_id stays :guest (P1)" do
      previous = Application.get_env(:fermix_channels, :slack, [])
      Application.put_env(:fermix_channels, :slack, allowed_user_ids: ["alice"])
      on_exit(fn -> Application.put_env(:fermix_channels, :slack, previous) end)

      source = %Source{channel: "slack", channel_key: :slack, sender_id: "alice"}

      assert {:ok, %Authorization{role: :guest, trust: :guest}} =
               Authorizer.resolve(source)
    end
  end

  describe "Source.from_message/1" do
    test "extracts user_id from atom-keyed metadata" do
      msg = %{channel: "telegram", chat_id: "chat-1", metadata: %{user_id: "owner-1"}}
      source = Source.from_message(msg)

      assert source.channel == "telegram"
      assert source.channel_key == :telegram
      assert source.sender_id == "owner-1"
      assert source.chat_id == "chat-1"
    end

    test "extracts user_id from string-keyed metadata" do
      msg = %{channel: "telegram", chat_id: "chat-1", metadata: %{"user_id" => "owner-1"}}
      source = Source.from_message(msg)

      assert source.sender_id == "owner-1"
    end

    test "falls back to sender_id when user_id is missing" do
      msg = %{channel: "telegram", chat_id: "c", metadata: %{sender_id: "fallback-1"}}
      source = Source.from_message(msg)

      assert source.sender_id == "fallback-1"
    end

    test "trims whitespace and collapses empty strings to nil" do
      msg = %{channel: "telegram", chat_id: "c", metadata: %{user_id: "   "}}
      source = Source.from_message(msg)

      assert source.sender_id == nil
    end

    test "coerces non-binary user_id to string" do
      msg = %{channel: "telegram", chat_id: "c", metadata: %{user_id: 12_345}}
      source = Source.from_message(msg)

      assert source.sender_id == "12345"
    end

    test "treats cli channel as having no channel_key" do
      msg = %{channel: "cli", chat_id: "c", metadata: %{}}
      source = Source.from_message(msg)

      assert source.channel == "cli"
      assert source.channel_key == nil
    end

    test "raises when channel field is missing or non-binary" do
      assert_raise ArgumentError, fn -> Source.from_message(%{chat_id: "c"}) end
    end
  end

  describe "resolve/1 ∘ Source.from_message/1 (end-to-end)" do
    test "owner message via Source.from_message resolves to :operator" do
      msg = %{channel: "telegram", chat_id: "c", metadata: %{user_id: "owner-1"}}

      assert {:ok, %Authorization{trust: :operator}} =
               msg |> Source.from_message() |> Authorizer.resolve()
    end

    test "allowed non-owner message resolves to :guest" do
      msg = %{channel: "telegram", chat_id: "c", metadata: %{user_id: "helper-1"}}

      assert {:ok, %Authorization{trust: :guest}} =
               msg |> Source.from_message() |> Authorizer.resolve()
    end

    test "stranger message is denied end-to-end" do
      msg = %{channel: "telegram", chat_id: "c", metadata: %{user_id: "stranger"}}

      assert {:error, :unauthorized} =
               msg |> Source.from_message() |> Authorizer.resolve()
    end
  end
end
