defmodule FermixCore.Delivery.OwnerInboxTest do
  # async: false — "derives only from an explicit owner id" is a statement about
  # real channel configuration, which lives in global `Application` env. That
  # case establishes its own precondition in the test and restores it on exit;
  # every other case injects the `:configured_owners`/`:jobs_config` seams.
  use ExUnit.Case, async: false

  alias FermixCore.Delivery.OwnerInbox

  @owner_channels [:telegram, :discord, :signal, :slack, :whatsapp]

  describe "resolve/1 precedence" do
    test "the configured jobs target wins when it is the owner's own inbox" do
      assert {:ok,
              %{
                platform: "telegram",
                destination: "owner-1",
                thread_scope: "root",
                source: :configured
              }} =
               OwnerInbox.resolve(
                 configured_owners: %{"telegram" => "owner-1"},
                 jobs_config: [
                   default_delivery_target: [platform: "telegram", chat_id: "owner-1"]
                 ]
               )
    end

    test "a target that is not the owner's inbox falls through to the derived rung" do
      assert {:ok, %{platform: "telegram", destination: "owner-1", source: :derived}} =
               OwnerInbox.resolve(
                 configured_owners: %{"telegram" => "owner-1"},
                 jobs_config: [
                   default_delivery_target: [channel: "telegram", chat_id: "group-77"]
                 ]
               )
    end

    test "a local jobs target is the owner's inbox by construction" do
      assert {:ok, %{platform: "cli", destination: "local", source: :configured}} =
               OwnerInbox.resolve(
                 configured_owners: %{},
                 jobs_config: [default_delivery_target: [channel: "cli", chat_id: "local"]]
               )
    end

    test "no configured target and no owner-configured channel is :no_delivery_target" do
      assert :no_delivery_target =
               OwnerInbox.resolve(configured_owners: %{}, jobs_config: [])
    end
  end

  describe "derived_candidates/1" do
    test "derivation follows one fixed order: telegram, then signal, then whatsapp" do
      owners = %{"whatsapp" => "owner-w", "signal" => "owner-s", "telegram" => "owner-t"}

      assert [
               %{platform: "telegram", destination: "owner-t"},
               %{platform: "signal", destination: "owner-s"},
               %{platform: "whatsapp", destination: "owner-w"}
             ] = OwnerInbox.derived_candidates(configured_owners: owners)

      assert {:ok, %{platform: "telegram"}} =
               OwnerInbox.resolve(configured_owners: owners, jobs_config: [])
    end

    test "every derived inbox is root-scoped and labelled :derived" do
      assert [%{thread_scope: "root", source: :derived}] =
               OwnerInbox.derived_candidates(configured_owners: %{"signal" => "owner-s"})
    end

    test "only channels whose DM destination is the bare owner id are derivable" do
      # A Discord/Slack DM needs a channel-id derivation the adapters do not
      # have, and `cli` is not a durable destination at all: a derived send
      # would fail while every gate reported OK.
      owners = %{"discord" => "owner-d", "slack" => "owner-sl", "cli" => "local"}

      assert [] = OwnerInbox.derived_candidates(configured_owners: owners)

      assert :no_delivery_target =
               OwnerInbox.resolve(configured_owners: owners, jobs_config: [])
    end

    test "no owner-configured channel yields no candidates" do
      assert [] = OwnerInbox.derived_candidates(configured_owners: %{})
    end
  end

  describe "configured_owners/0" do
    setup do
      previous = Map.new(@owner_channels, &{&1, Application.get_env(:fermix_channels, &1)})

      on_exit(fn ->
        Enum.each(previous, fn
          {channel, nil} -> Application.delete_env(:fermix_channels, channel)
          {channel, value} -> Application.put_env(:fermix_channels, channel, value)
        end)
      end)

      Enum.each(@owner_channels, &Application.delete_env(:fermix_channels, &1))

      :ok
    end

    test "derives only from channels carrying an explicit owner id" do
      # Channel PRESENCE is not an owner identity: a configured channel with no
      # `owner_user_id` (and an allowed-user list that does not elevate anyone)
      # is not an inbox.
      Application.put_env(:fermix_channels, :signal, enabled: true)
      Application.put_env(:fermix_channels, :whatsapp, allowed_sender_ids: ["friend-1"])
      Application.put_env(:fermix_channels, :telegram, enabled: true, owner_user_id: "555")

      assert OwnerInbox.configured_owners() == %{"telegram" => "555"}

      assert {:ok, %{platform: "telegram", destination: "555", source: :derived}} =
               OwnerInbox.resolve(jobs_config: [])
    end

    test "no configured channel means no owners and no inbox" do
      assert OwnerInbox.configured_owners() == %{}
      assert :no_delivery_target = OwnerInbox.resolve(jobs_config: [])
    end
  end
end
