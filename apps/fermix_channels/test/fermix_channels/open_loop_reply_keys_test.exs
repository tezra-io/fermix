defmodule FermixChannels.OpenLoopReplyKeysTest do
  @moduledoc """
  A rung 2 check-in (MILESTONE_83 §07) is recorded under the loop's delivery
  target, the inbox `Delivery.OwnerInbox` picked when the loop was noted, and
  the owner's reply is taken from the turn whose `ConversationKey` matches it.
  For every platform that ladder can pick and deliver to, this proves the
  owner's next DM, parsed by that platform's own gateway, carries the key the
  check-in was recorded under, so the reply is captured.

  Every name, number, handle and date here is invented.
  """

  # async: false — open loops follow `[fermix_core.open_loops] enabled`, and the
  # Signal and WhatsApp adapters parse only while their channel is enabled:
  # global app env this module pins in setup and restores on exit.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.IMessage
  alias FermixChannels.Channels.Signal
  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Gateway.Source
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Reactions
  alias FermixCore.OpenLoops.Registry

  defmodule Inbox do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: :ok
  end

  # Monday 2031-06-02: the loop is noted; the check-in goes out a week later.
  @said ~U[2031-06-02 14:00:00Z]
  @sent ~U[2031-06-09 13:00:00Z]
  @replied ~U[2031-06-09 13:20:00Z]
  @check_in "Did the Linden Street lease come through?"
  @reply "It came through yesterday"

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-open-loop-reply-keys-#{unique}.db")
    repo = :"open_loop_reply_keys_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    previous = [
      {:fermix_core, :open_loops, Application.get_env(:fermix_core, :open_loops)},
      {:fermix_channels, :signal, Application.get_env(:fermix_channels, :signal)},
      {:fermix_channels, :whatsapp, Application.get_env(:fermix_channels, :whatsapp)}
    ]

    Application.put_env(:fermix_core, :open_loops, enabled: true)
    Application.put_env(:fermix_channels, :signal, enabled: true)
    Application.put_env(:fermix_channels, :whatsapp, enabled: true)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, nil} -> Application.delete_env(app, key)
        {app, key, value} -> Application.put_env(app, key, value)
      end)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  # A Telegram private chat's id is its user's id.
  test "Telegram: the owner's DM is keyed by the owner id the check-in went to", ctx do
    update = %{
      "update_id" => 9_001,
      "message" => %{
        "message_id" => 77,
        "from" => %{"id" => 40_031, "is_bot" => false, "first_name" => "Lin"},
        "chat" => %{"id" => 40_031, "type" => "private", "first_name" => "Lin"},
        "date" => 1_939_000_000,
        "text" => @reply
      }
    }

    {:ok, [message]} = Telegram.parse_update(update)
    assert_reply_captured(ctx, "telegram", "40031", message)
  end

  test "Signal: the owner's DM is keyed by their number, the inbox's destination", ctx do
    entry = %{
      "envelope" => %{
        "sourceNumber" => "+15550104477",
        "sourceName" => "Lin",
        "timestamp" => 1_939_000_000_000,
        "dataMessage" => %{"timestamp" => 1_939_000_000_000, "message" => @reply}
      }
    }

    {:ok, [message]} = Signal.parse_receive_entry(entry)
    assert_reply_captured(ctx, "signal", "+15550104477", message)
  end

  test "WhatsApp: the owner's DM is keyed by their wa_id, the inbox's destination", ctx do
    params = %{
      "entry" => [
        %{
          "changes" => [
            %{
              "value" => %{
                "metadata" => %{"phone_number_id" => "pn_5550100"},
                "contacts" => [%{"wa_id" => "15550104477", "profile" => %{"name" => "Lin"}}],
                "messages" => [
                  %{
                    "from" => "15550104477",
                    "id" => "wamid.reply-1",
                    "timestamp" => "1939000000",
                    "type" => "text",
                    "text" => %{"body" => @reply}
                  }
                ]
              }
            }
          ]
        }
      ]
    }

    {:ok, [message]} = WhatsApp.parse_webhook(params)
    assert_reply_captured(ctx, "whatsapp", "15550104477", message)
  end

  # The config loader stores the owner's handle normalized
  # (`Setup.ConfigStore`), and the gateway normalizes every sender's handle by
  # the same rule, so a handle the helper spells differently keys the same DM.
  test "iMessage: the owner's DM is keyed by their normalized handle, the inbox's destination",
       ctx do
    owner = FermixCore.IMessage.normalize_handle!("Lin.Okafor@Example.com")
    policy = %{posture: :dedicated_account, owner: owner, handles: [owner]}

    row = %{
      "rowid" => 4_021,
      "guid" => "guid-reply-1",
      "chat" => %{
        "rowid" => 17,
        "guid" => "any;-;Lin.Okafor@Example.com",
        "identifier" => "Lin.Okafor@Example.com",
        "service" => "iMessage",
        "group" => false
      },
      "sender" => %{
        "handle" => "Lin.Okafor@Example.com",
        "service" => "iMessage",
        "is_me" => false
      },
      "date" => "2031-06-09T13:20:00Z",
      "text" => @reply,
      "decode_error" => nil,
      "reply_to_guid" => nil,
      "attachments" => [],
      "reaction" => nil
    }

    {:ok, message} = IMessage.parse_row(row, policy, %{})
    assert_reply_captured(ctx, "imessage", owner, message)
  end

  # The loop is noted with `owner` as the platform's configured owner, so the
  # ladder picks that DM; the check-in is recorded where it was sent; and the
  # owner's message, as the gateway parsed it, is the owner's private turn, keys
  # the same conversation, and is captured as the turn runner captures it: what
  # the owner typed (`UntrustedContent.owner_text/1`).
  defp assert_reply_captured(ctx, platform, owner, message) do
    loop = note!(ctx, platform, owner)
    assert {loop.delivery_platform, loop.delivery_destination} == {platform, owner}
    sent_opts = [repo: ctx.repo, raised_after_outside_content: false]
    {:ok, sent} = Reactions.record_sent(loop, @check_in, @sent, sent_opts)

    assert Source.from_message(message).sender_id == owner

    turn = %{
      conversation_key: ConversationKey.from(message),
      source_trust: :operator,
      computer_use_origin: :interactive,
      channel: message.channel,
      chat_type: message.metadata.chat_type,
      memory_repo: ctx.repo,
      memory_owner_id: "default",
      memory_agent_id: "main"
    }

    assert {:ok, 1} = Reactions.capture(turn, UntrustedContent.owner_text(message), @replied)
    {:ok, [row]} = Repo.list_open_loop_reactions("default", server: ctx.repo)
    assert %{id: id, outcome: "replied", reply_text: @reply} = row
    assert id == sent.id
  end

  defp note!(ctx, platform, owner) do
    params = %{
      "intention" => "Sign the Linden Street lease",
      "timezone" => "Etc/UTC",
      "reach" => "message",
      "matters_by" => %{"type" => "date", "date" => "2031-06-20"}
    }

    attended = %{
      source_trust: :operator,
      computer_use_origin: :interactive,
      conversation_key: {platform, owner, :root},
      chat_type: "private",
      memory_owner_id: "default",
      memory_agent_id: "main"
    }

    opts = [
      repo: ctx.repo,
      now: @said,
      jobs_config: [delivery_channels: %{platform => Inbox}],
      configured_owners: %{platform => owner},
      scheduler: nil
    ]

    {:ok, %{loop: loop}} = Registry.note(params, attended, opts)
    loop
  end
end
