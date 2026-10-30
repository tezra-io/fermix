defmodule FermixChannels.Gateway.OwnerInboxApprovalTest do
  @moduledoc """
  The owner-inbox half of the access-sensitive gate: a turn on a channel with no
  slash commands (ACP) sends its confirmation to the owner's own DM, bound to
  that DM's origin, through the single delivery path.
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.OwnerInboxApproval
  alias FermixChannels.Gateway.Source
  alias FermixCore.Cues.Proposals, as: CueProposals

  # A Telegram-shaped adapter that reports every send to the test.
  defmodule StubAdapter do
    def build_text_reply(message), do: fn text -> report({:text, message, text}) end
    def build_media_reply(message), do: fn part -> report({:media, message, part}) end

    def send_approval(message, text, token) do
      report({:approval, message, text, token})

      case Process.get(:stub_adapter_result, :ok) do
        result when is_function(result, 1) -> result.(token)
        result -> result
      end
    end

    defp report(event) do
      send(Process.get(:stub_adapter_test_pid) || self(), {:stub_adapter, event})
      :ok
    end
  end

  # A channel that draws a kind-aware card (Telegram's spec form): reports the
  # spec it was handed.
  defmodule CardAdapter do
    def build_text_reply(_message), do: fn _text -> :ok end
    def build_media_reply(_message), do: fn _part -> :ok end

    def send_approval(message, spec) do
      send(Process.get(:stub_adapter_test_pid) || self(), {:card_adapter, message, spec})
      Process.get(:stub_adapter_result, :ok)
    end
  end

  setup do
    previous_telegram = Application.get_env(:fermix_channels, :telegram, [])

    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: "owner-1",
      allowed_user_ids: ["owner-1"],
      command_allowlist: []
    )

    Process.put(:stub_adapter_test_pid, self())
    on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous_telegram) end)
    :ok
  end

  defp request(id \\ unique_id()),
    do: %{access_sensitive: id, prompt: "Confirm tesla_unlock_doors? Unlock the car's doors."}

  defp unique_id, do: "intent-#{System.unique_integer([:positive])}"

  defp telegram_owner(extra \\ []) do
    Keyword.merge(
      [jobs_config: [], configured_owners: %{"telegram" => "owner-1"}, adapter: StubAdapter],
      extra
    )
  end

  test "binds the token to the owner's DM and delivers a one-tap prompt there" do
    assert {:ok, token, :new} = OwnerInboxApproval.request(request(), telegram_owner())

    assert_received {:stub_adapter, {:approval, message, text, ^token}}
    assert message.channel == "telegram"
    assert message.reply_target == "owner-1"
    assert message.thread_ts == nil
    assert text =~ "tesla_unlock_doors"
    assert text =~ "/confirm #{token}"
    # Nothing resumes: the daemon runs the confirmed command itself.
    assert text =~ "Fermix runs exactly this command"
    refute text =~ "resume"

    assert {:ok, record} = Confirmations.peek(token)
    assert record.channel == "telegram"
    assert record.chat_id == "owner-1"
    assert record.thread_ts == nil
    assert record.user_id == "owner-1"
    assert record.resume == nil
  end

  test "a repeat for a live prompt sends nothing" do
    request = request()
    assert {:ok, token, :new} = OwnerInboxApproval.request(request, telegram_owner())
    assert_received {:stub_adapter, {:approval, _message, _text, ^token}}

    assert {:ok, ^token, :existing} = OwnerInboxApproval.request(request, telegram_owner())
    refute_received {:stub_adapter, _}
  end

  test "the owner's own DM /confirm passes the origin check" do
    assert {:ok, token, :new} = OwnerInboxApproval.request(request(), telegram_owner())

    message =
      Message.new!(%{
        id: "dm-#{System.unique_integer([:positive])}",
        content: "/confirm #{token}",
        sender: "owner",
        channel: "telegram",
        chat_id: "owner-1",
        reply_target: "owner-1",
        metadata: %{user_id: "owner-1", chat_type: "private"}
      })

    {:ok, authorization} =
      message |> Map.from_struct() |> Source.from_message(nil) |> Authorizer.resolve()

    test_pid = self()
    reply_fn = fn part -> send(test_pid, {:reply, part}) end

    assert :ok =
             Commands.dispatch(Commands.parse(message), reply_fn, %{
               authorization: authorization,
               conversation_key: {"telegram", "owner-1", :root}
             })

    # The origin matched and the token was consumed; the core record is unknown
    # here, so the reply reports that instead of an origin mismatch.
    assert_receive {:reply, {:text, reply}}, 2_000
    assert reply =~ "Confirmed, but"
    refute reply =~ "origin_mismatch"
    assert :error = Confirmations.peek(token)
  end

  # MILESTONE_54 §7.5: an iMessage conversation is keyed by the counterpart's
  # handle, so the owner's DM chat id is the owner id, as on Telegram.
  test "an iMessage owner inbox qualifies: its DM chat id is the owner's handle" do
    owner = "+15551234567"

    opts =
      telegram_owner(
        jobs_config: [default_delivery_target: %{channel: "imessage", chat_id: owner}],
        configured_owners: %{"imessage" => owner}
      )

    assert {:ok, token, :new} = OwnerInboxApproval.request(request(), opts)

    assert_received {:stub_adapter, {:approval, message, _text, ^token}}
    assert message.channel == "imessage"
    assert message.reply_target == owner

    assert {:ok, record} = Confirmations.peek(token)
    assert record.channel == "imessage"
    assert record.chat_id == owner
  end

  test "no owner inbox, or one on a platform whose DM is not the owner id, is refused" do
    assert {:error, :no_owner_inbox} =
             OwnerInboxApproval.request(request(), telegram_owner(configured_owners: %{}))

    for platform <- ["slack", "discord"] do
      configured = [default_delivery_target: %{channel: platform, chat_id: "owner-1"}]
      owners = %{platform => "owner-1"}

      assert {:error, :no_owner_inbox} =
               OwnerInboxApproval.request(
                 request(),
                 telegram_owner(jobs_config: configured, configured_owners: owners)
               )
    end

    local = [default_delivery_target: %{channel: "cli", chat_id: "cli"}]

    assert {:error, :no_owner_inbox} =
             OwnerInboxApproval.request(request(), telegram_owner(jobs_config: local))

    refute_received {:stub_adapter, _}
  end

  test "a delivery failure takes the token back" do
    Process.put(:stub_adapter_result, {:error, :telegram_down})

    assert {:error, {:owner_inbox_unreachable, :telegram_down}} =
             OwnerInboxApproval.request(request(), telegram_owner())

    assert_received {:stub_adapter, {:approval, _message, _text, token}}
    assert :error = Confirmations.peek(token)
  end

  # A racing `/deny` or the expiry sweep can take the token while the delivery
  # fails; none is left either way, so the request is refused, not crashed.
  test "a delivery failure after the token was already taken still refuses" do
    Process.put(:stub_adapter_result, fn token ->
      {:ok, _record} = Confirmations.take(token)
      {:error, :telegram_down}
    end)

    assert {:error, {:owner_inbox_unreachable, :telegram_down}} =
             OwnerInboxApproval.request(request(), telegram_owner())
  end

  # --- a watcher's card (M60_WATCHER_CODING_RUNS.md §4.5, §6) --------------------------

  describe "send_follow_up/2" do
    test "sends the compact card with a fresh token to the owner's DM, and says where it went" do
      opts = telegram_owner(adapter: CardAdapter, now: ~U[2026-10-30 12:01:00Z])

      assert {:ok, binding} = OwnerInboxApproval.send_follow_up(follow_up_card(), opts)

      assert_received {:card_adapter, message, spec}
      assert message.reply_target == "owner-1"
      assert spec.kind == :follow_up
      assert "cp_" <> _rest = spec.token
      assert hd(spec.lines) == ~s(Run "Deploy check"?)
      assert List.last(spec.lines) =~ "· reports here"
      assert spec.actions == %{confirm: "▶ Run", deny: "Skip"}
      assert spec.text =~ "Reply /confirm to run or /deny to skip."

      assert binding == %{
               token_digest: CueProposals.digest(spec.token),
               platform: "telegram",
               chat_id: "owner-1",
               user_id: "owner-1"
             }
    end

    test "an automatic follow-up's prompt asks to approve or keep asking" do
      opts = telegram_owner(adapter: CardAdapter)

      assert {:ok, %{token_digest: digest}} =
               OwnerInboxApproval.send_follow_up(approval_card(), opts)

      assert_received {:card_adapter, _message, spec}
      assert spec.actions == %{confirm: "✅ Approve", deny: "❌ Keep asking"}
      assert spec.text =~ "at most 5 a day"
      assert digest == CueProposals.digest(spec.token)
    end

    test "with no DM it goes to the apps alone when one can show it, else nowhere" do
      local = [default_delivery_target: %{channel: "cli", chat_id: "cli"}]
      opts = telegram_owner(adapter: CardAdapter, jobs_config: local, configured_owners: %{})

      assert {:ok, %{token_digest: nil, platform: nil, chat_id: nil, user_id: nil}} =
               OwnerInboxApproval.send_follow_up(follow_up_card(), [app_surface?: true] ++ opts)

      assert {:error, {:unreachable, _sentence}} =
               OwnerInboxApproval.send_follow_up(follow_up_card(), [app_surface?: false] ++ opts)

      refute_received {:card_adapter, _message, _spec}
    end

    test "a send that fails leaves it to the apps when one can show it, else refuses it" do
      Process.put(:stub_adapter_result, {:error, :telegram_down})
      opts = telegram_owner(adapter: CardAdapter)

      assert {:ok, %{token_digest: nil}} =
               OwnerInboxApproval.send_follow_up(follow_up_card(), [app_surface?: true] ++ opts)

      assert {:error, :telegram_down} =
               OwnerInboxApproval.send_follow_up(follow_up_card(), [app_surface?: false] ++ opts)
    end
  end

  test "a mandate's proposal goes as its compact card" do
    spec = %{
      kind: :mandate,
      text: "card",
      token: "cp_X",
      lines: ["Run x?"],
      detail: "D",
      actions: %{confirm: "▶ Run", deny: "Skip"}
    }

    assert :ok =
             OwnerInboxApproval.send_cue_proposal(
               %{platform: "telegram", destination: "owner-1"},
               spec,
               adapter: CardAdapter
             )

    assert_received {:card_adapter, %{reply_target: "owner-1"}, ^spec}
  end

  defp follow_up_card do
    %{
      trigger_id: "cft_1",
      state: "waiting",
      expires_at: ~U[2026-10-30 12:30:00Z],
      watcher: %{id: "cwt_1", name: "release-watch"},
      follow_up: %{
        job_id: "job_1",
        name: "Deploy check",
        instructions: "Run the deploy check script and report what failed.",
        tools: ["shell"],
        delivery: %{mode: "origin", target: %{"platform" => "telegram", "chat_id" => "owner-1"}}
      },
      outside: %{
        source_ref: "releases",
        received_at: ~U[2026-10-30 11:59:00Z],
        occurred_at: nil,
        type: "release",
        subject: "kestrel",
        text: "Kestrel 2.4 is out.",
        reason: nil
      }
    }
  end

  defp approval_card do
    %{
      id: "cfa_1",
      shown_digest: "digest",
      watcher_name: "release-watch",
      expires_at: ~U[2026-10-30 12:30:00Z],
      daily_cap: 5,
      sources: ["releases"],
      listen_for: [],
      job_id: "job_1",
      job_name: "Deploy check",
      task_prompt: "Run the deploy check script and report what failed.",
      allowed_tools: ["shell"],
      delivery_mode: "origin",
      delivery_target: %{"platform" => "telegram", "chat_id" => "owner-1"}
    }
  end
end
