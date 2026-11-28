defmodule FermixCore.Delivery.OwnerInboxTest do
  # async: false — "derives only from an explicit owner id" is a statement about
  # real channel configuration, which lives in global `Application` env. That
  # case establishes its own precondition in the test and restores it on exit;
  # every other case injects the `:configured_owners`/`:jobs_config` seams.
  use ExUnit.Case, async: false

  alias FermixCore.Delivery.OwnerInbox

  @owner_channels [:telegram, :discord, :signal, :slack, :whatsapp, :imessage]

  # A remote platform's adapter: it sends, and its inbox is derived from the
  # owner id configured for it.
  defmodule RemoteAdapter do
    def send_message(_destination, _text, _opts), do: :ok
  end

  # A transport only the owner reaches (the Mac's chat socket): its adapter
  # names the owner's inbox itself.
  defmodule TransportAdapter do
    def send_message(_destination, _text, _opts), do: :ok
    def owner_inbox, do: {:ok, "main"}
  end

  # The same kind of transport while it cannot deliver (the phones' channel
  # not running).
  defmodule AwayTransportAdapter do
    def send_message(_destination, _text, _opts), do: :ok
    def owner_inbox, do: :unavailable
  end

  # The phones' channel with a phone whose pairing completed (M106 §8, D3).
  defmodule PairedPhoneAdapter do
    def send_message(_destination, _text, _opts), do: :ok
    def owner_inbox, do: {:ok, "main"}
    def phone_paired?, do: true
  end

  # The phones' channel running with no phone paired: on, and nobody to read.
  defmodule UnpairedPhoneAdapter do
    def send_message(_destination, _text, _opts), do: :ok
    def owner_inbox, do: {:ok, "main"}
    def phone_paired?, do: false
  end

  # The phones' channel of an Always On server: no phone, and a computer of
  # the home linked to it (the owner's Mac, which tunnels the chat).
  defmodule LinkedComputerAdapter do
    def send_message(_destination, _text, _opts), do: :ok
    def owner_inbox, do: {:ok, "main"}
    def phone_paired?, do: false
    def computer_linked?, do: true
  end

  # An adapter that answers the question with something it is not.
  defmodule ConfusedPhoneAdapter do
    def send_message(_destination, _text, _opts), do: :ok
    def owner_inbox, do: {:ok, "main"}
    def phone_paired?, do: :maybe
  end

  @channels %{
    "telegram" => RemoteAdapter,
    "slack" => RemoteAdapter,
    "signal" => RemoteAdapter,
    "companion" => TransportAdapter,
    "mobile" => AwayTransportAdapter,
    "cli" => RemoteAdapter
  }

  @paired Map.put(@channels, "mobile", PairedPhoneAdapter)
  @unpaired Map.put(@channels, "mobile", UnpairedPhoneAdapter)
  @linked Map.put(@channels, "mobile", LinkedComputerAdapter)
  @app %{platform: "companion", destination: "main", thread_scope: "root"}

  describe "on_platform/2" do
    test "a remote platform's inbox is the owner DM its owner id derives" do
      assert {:ok,
              %{
                platform: "telegram",
                destination: "owner-t",
                thread_scope: "root",
                source: :derived
              }} =
               OwnerInbox.on_platform("telegram",
                 configured_owners: %{"telegram" => "owner-t", "signal" => "owner-s"},
                 jobs_config: [delivery_channels: @channels]
               )
    end

    test "the configured target is the inbox of its own platform only" do
      opts = [
        configured_owners: %{"telegram" => "owner-t", "slack" => "U1"},
        jobs_config: [
          delivery_channels: @channels,
          default_delivery_target: [platform: "slack", chat_id: "U1"]
        ]
      ]

      assert {:ok, %{platform: "slack", destination: "U1", source: :configured}} =
               OwnerInbox.on_platform("slack", opts)

      # The configured target is Slack's, so Telegram still answers its own DM,
      # never the configured target.
      assert {:ok, %{platform: "telegram", destination: "owner-t", source: :derived}} =
               OwnerInbox.on_platform("telegram", opts)
    end

    test "a platform with no owner inbox is refused, never answered with another's" do
      opts = [
        configured_owners: %{"telegram" => "owner-t"},
        jobs_config: [delivery_channels: @channels]
      ]

      # Slack has no derivable DM and no configured target; Signal has no owner.
      assert {:error, :no_owner_inbox} = OwnerInbox.on_platform("slack", opts)
      assert {:error, :no_owner_inbox} = OwnerInbox.on_platform("signal", opts)
      # The CLI prints to the daemon's own output: it is no inbox.
      assert {:error, :no_owner_inbox} = OwnerInbox.on_platform("cli", opts)
    end

    test "a transport only the owner reaches names its own inbox, while it can deliver" do
      opts = [configured_owners: %{}, jobs_config: [delivery_channels: @channels]]

      assert {:ok,
              %{
                platform: "companion",
                destination: "main",
                thread_scope: "root",
                source: :transport
              }} = OwnerInbox.on_platform("companion", opts)

      assert {:error, :no_owner_inbox} = OwnerInbox.on_platform("mobile", opts)
    end

    test "a platform that is not a delivery channel is refused with the send path's reason" do
      opts = [
        configured_owners: %{"discord" => "owner-d"},
        jobs_config: [delivery_channels: @channels]
      ]

      assert {:error, {:unsupported_delivery_platform, "discord"}} =
               OwnerInbox.on_platform("discord", opts)

      assert {:error, {:unsupported_delivery_platform, "voice"}} =
               OwnerInbox.on_platform("voice", opts)
    end
  end

  describe "reachable_platforms/1" do
    test "names every delivery channel with an owner inbox now, in name order" do
      assert OwnerInbox.reachable_platforms(
               configured_owners: %{"telegram" => "owner-t"},
               jobs_config: [delivery_channels: @channels]
             ) == ["companion", "telegram"]
    end

    test "is empty when no delivery channel is configured" do
      assert OwnerInbox.reachable_platforms(
               configured_owners: %{"telegram" => "owner-t"},
               jobs_config: [delivery_channels: %{}]
             ) == []
    end
  end

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

  describe "for_approval/2 (M97 §14: a sleeping Mac is no inbox for a prompt that waits)" do
    @owners %{"imessage" => "+15550104477", "telegram" => "owner-t"}
    @imessage_target [
      default_delivery_target: %{"channel" => "imessage", "chat_id" => "+15550104477"}
    ]

    defp carried(connected),
      do:
        {:computer,
         %FermixCore.Computers.Computer{
           device_id: "d-7",
           name: "studio Mac",
           connected: connected
         }}

    test "iMessage on this Mac keeps its place, configured first" do
      assert {:ok, %{platform: "imessage", source: :configured}} =
               OwnerInbox.for_approval(
                 :approval_card,
                 configured_owners: @owners,
                 jobs_config: @imessage_target,
                 imessage_carrier: :here
               )
    end

    test "iMessage a computer carries comes after a channel that lives on the server" do
      assert {:ok, %{platform: "telegram", source: :derived}} =
               OwnerInbox.for_approval(
                 :approval_card,
                 configured_owners: @owners,
                 jobs_config: @imessage_target,
                 imessage_carrier: carried(true)
               )
    end

    test "iMessage a connected computer carries is chosen when it is the only inbox" do
      assert {:ok, %{platform: "imessage", destination: "+15550104477"}} =
               OwnerInbox.for_approval(
                 :approval_card,
                 configured_owners: %{"imessage" => "+15550104477"},
                 jobs_config: [],
                 imessage_carrier: carried(true)
               )
    end

    test "iMessage is never chosen while the Mac that carries it is away, or nobody carries it" do
      for carrier <- [carried(false), :none, {:conflict, []}] do
        assert :no_delivery_target =
                 OwnerInbox.for_approval(
                   :approval_card,
                   configured_owners: %{"imessage" => "+15550104477"},
                   jobs_config: @imessage_target,
                   imessage_carrier: carrier
                 )
      end
    end

    test "the carrier is not read when no iMessage inbox is a candidate" do
      assert {:ok, %{platform: "telegram"}} =
               OwnerInbox.for_approval(
                 :approval_card,
                 configured_owners: %{"telegram" => "owner-t"},
                 jobs_config: [],
                 imessage_carrier: :not_read
               )
    end
  end

  # M106 §8, D3, D9, D12: the Fermix app is the owner's inbox, first while a
  # phone is paired and last when nothing else is, for telling and for asking
  # on an approval card. A watcher's proposal card never goes there.
  describe "the Fermix app's inbox" do
    @dm %{"telegram" => "owner-t"}

    test "a paired phone puts the app first, before every DM, for a tell and an ask" do
      opts = [configured_owners: @dm, jobs_config: [delivery_channels: @paired]]

      assert OwnerInbox.resolve(opts) == {:ok, Map.put(@app, :source, :derived)}
      assert OwnerInbox.for_approval(:approval_card, opts) == OwnerInbox.resolve(opts)
    end

    test "without a paired phone the DM comes first, though the phones' channel is on" do
      for channels <- [@unpaired, @channels, Map.delete(@channels, "mobile")] do
        opts = [configured_owners: @dm, jobs_config: [delivery_channels: channels]]

        assert {:ok, %{platform: "telegram", destination: "owner-t"}} = OwnerInbox.resolve(opts)

        assert {:ok, %{platform: "telegram"}} =
                 OwnerInbox.for_approval(:approval_card, opts ++ [app_surface?: true])
      end
    end

    test "the Mac chat alone is an inbox, last, on an engine with an app (D9)" do
      alone = [configured_owners: %{}, jobs_config: [delivery_channels: @unpaired]]

      assert {:ok, %{platform: "companion", destination: "main"}} =
               OwnerInbox.resolve(alone ++ [app_surface?: true])

      assert {:ok, %{platform: "companion"}} =
               OwnerInbox.for_approval(:approval_card, alone ++ [app_surface?: true])

      assert :no_delivery_target = OwnerInbox.resolve(alone ++ [app_surface?: false])

      assert :no_delivery_target =
               OwnerInbox.for_approval(:approval_card, alone ++ [app_surface?: false])

      with_dm = [configured_owners: @dm, jobs_config: [delivery_channels: @unpaired]]

      assert {:ok, %{platform: "telegram"}} =
               OwnerInbox.resolve(with_dm ++ [app_surface?: true])
    end

    # D9 on an Always On server (M106 §8): the home lives on an engine that is
    # no app's, and the owner's Mac reaches the chat through its computer's
    # link. A computer of the home is enough, connected or not.
    test "on an engine that is no app's, a linked computer makes the Mac chat the inbox, last" do
      server = [configured_owners: %{}, jobs_config: [delivery_channels: @linked]]

      for opts <- [server ++ [app_surface?: false], server] do
        assert {:ok, %{platform: "companion", destination: "main", source: :derived}} =
                 OwnerInbox.resolve(opts)

        assert {:ok, %{platform: "companion", destination: "main"}} =
                 OwnerInbox.for_approval(:approval_card, opts)
      end

      with_dm = [configured_owners: @dm, jobs_config: [delivery_channels: @linked]]
      assert {:ok, %{platform: "telegram"}} = OwnerInbox.resolve(with_dm)
      assert {:ok, %{platform: "telegram"}} = OwnerInbox.for_approval(:approval_card, with_dm)

      no_computer = [configured_owners: %{}, jobs_config: [delivery_channels: @unpaired]]
      assert :no_delivery_target = OwnerInbox.resolve(no_computer ++ [app_surface?: false])

      assert :no_delivery_target =
               OwnerInbox.for_approval(:approval_card, no_computer ++ [app_surface?: false])
    end

    # The watcher cards' reach keeps its own, narrower question (ruling 3).
    test "a linked computer changes nothing for a watcher's proposal card" do
      assert :no_delivery_target =
               OwnerInbox.for_approval(:proposal_card,
                 configured_owners: %{},
                 jobs_config: [delivery_channels: @linked]
               )

      assert {:ok, %{platform: "telegram"}} =
               OwnerInbox.for_approval(:proposal_card,
                 configured_owners: @dm,
                 jobs_config: [delivery_channels: @linked]
               )
    end

    test "a configured target still wins over a paired phone" do
      opts = [
        configured_owners: @dm,
        jobs_config: [
          delivery_channels: @paired,
          default_delivery_target: [channel: "telegram", chat_id: "owner-t"]
        ]
      ]

      assert {:ok, %{platform: "telegram", source: :configured}} = OwnerInbox.resolve(opts)
      assert {:ok, %{platform: "telegram"}} = OwnerInbox.for_approval(:approval_card, opts)
    end

    test "a configured target naming the phone or the Mac chat is the app's inbox" do
      for platform <- ["mobile", "companion"] do
        opts = [
          configured_owners: @dm,
          jobs_config: [
            delivery_channels: @unpaired,
            default_delivery_target: [channel: platform, chat_id: "main"]
          ]
        ]

        configured = Map.put(@app, :source, :configured)
        assert OwnerInbox.resolve(opts) == {:ok, configured}
        assert OwnerInbox.for_approval(:approval_card, opts) == {:ok, configured}
      end

      # A chat that is not the app's inbox is no inbox of the owner's.
      other_chat = [
        configured_owners: @dm,
        jobs_config: [
          delivery_channels: @unpaired,
          default_delivery_target: [channel: "companion", chat_id: "work"]
        ]
      ]

      assert {:ok, %{platform: "telegram", source: :derived}} = OwnerInbox.resolve(other_chat)
    end

    test "a watcher's proposal card goes where it went: a paired phone changes nothing" do
      paired = [configured_owners: @dm, jobs_config: [delivery_channels: @paired]]

      assert OwnerInbox.for_approval(:proposal_card, paired) ==
               OwnerInbox.for_approval(:proposal_card,
                 configured_owners: @dm,
                 jobs_config: [delivery_channels: @channels]
               )

      assert {:ok, %{platform: "telegram", source: :derived}} =
               OwnerInbox.for_approval(:proposal_card, paired)

      # No DM: the app is no chat for it, paired, configured or alone.
      app_target = [
        delivery_channels: @paired,
        default_delivery_target: [channel: "companion", chat_id: "main"]
      ]

      for opts <- [
            [configured_owners: %{}, jobs_config: [delivery_channels: @paired]],
            [configured_owners: %{}, jobs_config: app_target, app_surface?: true]
          ] do
        assert :no_delivery_target = OwnerInbox.for_approval(:proposal_card, opts)
      end
    end

    test "a reminder's derived rung never holds the app" do
      assert [%{platform: "telegram"}] =
               OwnerInbox.derived_candidates(
                 configured_owners: @dm,
                 jobs_config: [delivery_channels: @paired]
               )
    end

    test "a phones' channel that answers the question with no boolean fails loud" do
      opts = [
        configured_owners: @dm,
        jobs_config: [delivery_channels: Map.put(@channels, "mobile", ConfusedPhoneAdapter)]
      ]

      assert_raise CaseClauseError, fn -> OwnerInbox.resolve(opts) end
    end

    test "the app's inbox is answered from the app's one origin, and kept in its conversation" do
      origin = %{platform: "companion", chat_id: "main", user_id: "app"}

      assert OwnerInbox.answer_origin(@app) == {:ok, origin}
      assert OwnerInbox.app_origin("main") == origin
      assert OwnerInbox.history_conversation(@app) == {:ok, {"companion", "main", :root}}

      dm = %{platform: "signal", destination: "+15550100", thread_scope: "root"}
      assert OwnerInbox.history_conversation(dm) == {:ok, {"signal", "+15550100", :root}}

      for elsewhere <- [
            %{platform: "slack", destination: "U1"},
            %{platform: "cli", destination: "cli"},
            %{platform: "mobile", destination: "main"}
          ] do
        assert OwnerInbox.history_conversation(elsewhere) == :error
      end
    end

    test "an answer typed on the Mac chat or a paired phone is the app's, and nowhere else's" do
      origin = %{platform: "companion", chat_id: "main", user_id: "app"}

      assert OwnerInbox.answered_in_app("companion", "main") == {:ok, origin}
      assert OwnerInbox.answered_in_app("mobile", "main") == {:ok, origin}

      for platform <- ~w(telegram signal whatsapp imessage cli daemon slack voice) do
        assert OwnerInbox.answered_in_app(platform, "main") == :error
      end
    end

    test "a display names the app's inbox as a place, and every other as it always has" do
      assert OwnerInbox.place(@app) == "the Fermix app"

      for platform <- ~w(telegram signal whatsapp imessage slack discord cli) do
        assert OwnerInbox.place(%{platform: platform, destination: "x"}) == platform
      end
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

    # M54 §7.5: an iMessage direct conversation is keyed by the owner's handle,
    # so the owner id is the DM destination itself; it is derived last.
    test "an iMessage owner is a derived inbox, after every older channel" do
      owners = %{"imessage" => "+15551234567", "telegram" => "owner-t"}

      assert [
               %{platform: "telegram", destination: "owner-t"},
               %{platform: "imessage", destination: "+15551234567", source: :derived}
             ] = OwnerInbox.derived_candidates(configured_owners: owners)

      assert {:ok, %{platform: "imessage"}} =
               OwnerInbox.resolve(
                 configured_owners: %{"imessage" => "+15551234567"},
                 jobs_config: []
               )
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

  describe "dm_origin/1" do
    test "a DM whose chat id is the owner's user id answers that chat and user" do
      for platform <- ~w(telegram signal whatsapp imessage) do
        inbox = %{platform: platform, destination: "owner-1", thread_scope: "root"}

        assert OwnerInbox.dm_origin(inbox) ==
                 {:ok, %{platform: platform, chat_id: "owner-1", user_id: "owner-1"}}
      end
    end

    test "any other inbox has no origin a confirm can be checked against" do
      for inbox <- [
            %{platform: "slack", destination: "U1"},
            %{platform: "discord", destination: "123"},
            %{platform: "mobile", destination: "phone-1"},
            %{platform: "telegram", destination: ""}
          ] do
        assert OwnerInbox.dm_origin(inbox) == :error
      end
    end
  end

  # M106 §5.7 (stage S4b): a card is held to the chat its answer comes from,
  # a DM's or the local cli chat's, which only the owner types in.
  describe "answer_origin/1" do
    test "a DM answers as dm_origin/1 does; the local cli chat answers its own chat and user" do
      dm = %{platform: "signal", destination: "+15550100", thread_scope: "root"}
      assert OwnerInbox.answer_origin(dm) == OwnerInbox.dm_origin(dm)

      assert OwnerInbox.answer_origin(%{
               platform: "cli",
               destination: "cli",
               thread_scope: "root"
             }) ==
               {:ok, %{platform: "cli", chat_id: "cli", user_id: "cli"}}
    end

    test "any other inbox, and the cli for dm_origin/1, have none" do
      for inbox <- [
            %{platform: "slack", destination: "U1"},
            %{platform: "daemon", destination: "local"},
            %{platform: "cli", destination: ""}
          ] do
        assert OwnerInbox.answer_origin(inbox) == :error
      end

      assert OwnerInbox.dm_origin(%{platform: "cli", destination: "cli"}) == :error
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

    test "an iMessage owner id is read like every other channel's" do
      Application.put_env(:fermix_channels, :imessage, owner_user_id: "+15551234567")

      assert OwnerInbox.configured_owners() == %{"imessage" => "+15551234567"}
    end

    test "no configured channel means no owners and no inbox" do
      assert OwnerInbox.configured_owners() == %{}
      assert :no_delivery_target = OwnerInbox.resolve(jobs_config: [])
    end
  end
end
