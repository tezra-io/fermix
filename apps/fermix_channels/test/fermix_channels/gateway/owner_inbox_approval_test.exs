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
end
