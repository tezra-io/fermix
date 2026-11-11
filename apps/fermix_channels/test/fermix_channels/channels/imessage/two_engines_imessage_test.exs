defmodule FermixChannels.Channels.IMessage.TwoEnginesIMessageTest do
  @moduledoc """
  iMessage through a computer (M97 §6.4), over the real link with each
  engine's own home and processes in one VM (`TwoEngines`): the server runs
  the listener and the adapter through `IMessage.ComputerHelper`; the "Mac"
  runs the helper (a scripted double, `IMessageFakeHelper`) behind its
  `IMessage.Watch`, admitted by its own `Desktop.Invoke` under its own
  `imessage` switch.

  async: false: the relay's dial names and the Mac's watch name are VM-wide.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.IMessage
  alias FermixChannels.Channels.IMessage.ComputerHelper
  alias FermixChannels.Channels.IMessage.Listener
  alias FermixChannels.Channels.IMessage.Watch
  alias FermixChannels.Test.IMessageFakeHelper, as: FakeHelper
  alias FermixChannels.Test.TwoEngines
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Journal
  alias FermixCore.Computers.Registry
  alias FermixCore.Computers.Switches
  alias FermixCore.Delivery.Error, as: DeliveryError
  alias FermixTestSupport.SafeRm

  @owner "+15551234567"
  @guest "guest@example.com"
  @recipients %{owner: @owner, handles: [@owner, @guest]}

  # Every hand-off the listener makes, as `Gateway.Queue` would take it.
  defmodule CapturingAgent do
    @moduledoc false
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:fermix_channels, :imessage)
    Application.put_env(:fermix_channels, :imessage, enabled: true, owner_user_id: @owner)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_channels, :imessage)
        config -> Application.put_env(:fermix_channels, :imessage, config)
      end
    end)

    engines = TwoEngines.start!(offers: [:imessage])
    offers = TwoEngines.await_offers(engines)
    mac = mac!(engines)
    server_home = SafeRm.make_tmp_dir!("imessage_server")
    on_exit(fn -> SafeRm.rm_rf!(server_home) end)

    %{engines: engines, offers: offers, mac: mac, server_home: server_home}
  end

  # The Mac: its helper (a scripted double) and the watch the capability
  # reaches it through, under the Mac's own home.
  defp mac!(engines) do
    fake = :"imessage_mac_helper_#{System.unique_integer([:positive])}"

    start_supervised!(
      {FakeHelper, name: fake, home: engines.root, test_pid: self()},
      id: :mac_helper
    )

    start_supervised!(
      {Watch, name: Watch, helper: FakeHelper, server: fake, home: engines.root},
      id: :mac_watch
    )

    fake
  end

  # The server's view of the home's computers, as `Computers.list/1` builds
  # it: connected while its session is up, offering what it last said.
  defp computers(ctx, extra \\ fn -> [] end) do
    fn ->
      live = Registry.live(ctx.engines.registry)[ctx.engines.device_id]

      [
        %Computer{
          device_id: ctx.engines.device_id,
          name: "studio Mac",
          platform: :macos,
          connected: live != nil,
          offers: ctx.offers
        }
        | extra.()
      ]
    end
  end

  defp server!(ctx, opts \\ []) do
    helper = :"imessage_server_helper_#{System.unique_integer([:positive])}"
    listener = :"imessage_server_listener_#{System.unique_integer([:positive])}"

    start_supervised!(
      {ComputerHelper,
       name: helper,
       home: ctx.server_home,
       computers: Keyword.get(opts, :computers, computers(ctx)),
       call_opts: TwoEngines.call_opts(ctx.engines),
       poll_ms: 20,
       retry_ms: 50},
      id: :server_helper
    )

    start_supervised!(
      {Listener,
       name: listener,
       helper: ComputerHelper,
       server: helper,
       home: ctx.server_home,
       recipients: @recipients,
       agent: CapturingAgent,
       agent_server: self(),
       probe_retry_ms: 20,
       handoff_retry_ms: 20},
      id: :server_listener
    )

    %{helper: helper, listener: listener}
  end

  defp live!(ctx, server) do
    mac = ctx.mac
    assert_receive {:fake_helper_call, ^mac, "watch.subscribe", params}, 10_000
    assert_eventually(fn -> Listener.status(server.listener).phase == :live end)
    params
  end

  defp row(rowid, overrides \\ %{}) do
    Map.merge(
      %{
        "rowid" => rowid,
        "guid" => "F1C2E3A4-#{rowid}-#{System.unique_integer([:positive])}",
        "chat" => %{
          "rowid" => 17,
          "guid" => "any;-;#{@owner}",
          "identifier" => @owner,
          "service" => "iMessage",
          "group" => false
        },
        "sender" => %{"handle" => @owner, "service" => "iMessage", "is_me" => false},
        "date" => "2026-11-10T08:00:00Z",
        "text" => "message #{rowid}",
        "decode_error" => nil,
        "reply_to_guid" => nil,
        "attachments" => [],
        "reaction" => nil
      },
      overrides
    )
  end

  test "an incoming message on the Mac becomes a turn on the server", ctx do
    server = server!(ctx)
    params = live!(ctx, server)
    # The first subscription through a computer catches up within its bounds.
    assert params["since_rowid"] == nil

    FakeHelper.push(ctx.mac, "message", row(101, %{"text" => "are you on the server now?"}))

    assert_receive {:agent_message, message}, 10_000
    assert message.content == "are you on the server now?"
    assert message.channel == "imessage"
    assert message.metadata.imessage_server == server.helper

    # The cursor is the home's, kept per computer.
    cursor = Path.join([ctx.server_home, "imessage", "cursors", ctx.engines.device_id])

    assert_eventually(fn ->
      File.exists?(cursor) and
        match?(%{"rowid" => 101}, cursor |> File.read!() |> Jason.decode!())
    end)

    refute File.exists?(Path.join(ctx.engines.root, "imessage/cursors"))
  end

  test "a reply goes out through the Mac's helper, once, journaled there as a send", ctx do
    server = server!(ctx)
    live!(ctx, server)

    assert :ok =
             IMessage.send_message(@owner, "Yes, I still text you from here.",
               helper: ComputerHelper,
               server: server.helper,
               turn_id: "turn-81"
             )

    mac = ctx.mac
    assert_receive {:fake_helper_call, ^mac, "send.text", params}, 10_000
    assert params["to"] == @owner
    assert params["text"] == "Yes, I still text you from here."
    assert params["idempotency_key"] == "turn:turn-81:0:text:0"

    assert {:ok, %{entries: entries}} = Journal.list(Journal.dir(ctx.engines.root))

    assert %{target: target, origin: "chat", status: "ok"} =
             Enum.find(entries, &(&1.op == "imessage.send"))

    # A method and a shortened handle, never the text.
    assert target == "send.text to +1555…4567"
    refute Enum.any?(entries, &(&1.target =~ "still text"))
  end

  test "an attachment goes each way as bytes, and no path of the Mac's reaches the server",
       ctx do
    server = server!(ctx)
    live!(ctx, server)
    test_pid = self()

    # Outgoing: the Mac stages the bytes in its own outbox.
    FakeHelper.script(ctx.mac, "send.file", fn params ->
      send(test_pid, {:mac_file, params["path"], File.read!(params["path"])})
      {:ok, %{"disposition" => "recorded", "guid" => "sent-file-1", "rowid" => 4100}}
    end)

    upload = :crypto.strong_rand_bytes(90 * 1_024)
    file = Path.join(ctx.server_home, "chart.png")
    File.write!(file, upload)

    assert :ok =
             IMessage.send_media(
               @owner,
               %{path: file, mime_type: "image/png", filename: "chart.png"},
               helper: ComputerHelper,
               server: server.helper,
               turn_id: "turn-82"
             )

    assert_receive {:mac_file, mac_path, ^upload}, 10_000
    assert String.starts_with?(mac_path, Path.join(ctx.engines.root, "imessage/outbox"))
    refute File.exists?(mac_path)

    # Incoming: the Mac reads what its helper fetched, removes it, and the
    # server keeps the bytes in its own inbox.
    guid = "F1C2E3A4-0002-4B5C-9D6E-7F8091A2B3C4"
    photo = :crypto.strong_rand_bytes(70 * 1_024)
    mac_entry = Path.join([ctx.engines.root, "imessage", "inbox", guid])

    FakeHelper.script(ctx.mac, "attachment.fetch", fn _params ->
      File.mkdir_p!(mac_entry)
      File.write!(Path.join(mac_entry, "0-photo.jpeg"), photo)

      {:ok,
       %{"path" => Path.join(mac_entry, "0-photo.jpeg"), "mime" => "image/jpeg", "bytes" => 1}}
    end)

    policy = Map.put(@recipients, :posture, :dedicated_account)

    {:ok, message} =
      IMessage.parse_row(
        row(102, %{
          "guid" => guid,
          "attachments" => [%{"index" => 0, "mime" => "image/jpeg", "name" => "photo.jpeg"}]
        }),
        policy,
        %{helper: ComputerHelper, server: server.helper}
      )

    assert {:ok, path} = IMessage.download_attachment(message, hd(message.attachments))
    assert path == Path.join([ctx.server_home, "imessage", "inbox", guid, "0-photo.jpeg"])
    assert File.read!(path) == photo
    refute File.exists?(Path.join(mac_entry, "0-photo.jpeg"))
  end

  test "the Mac away: a send fails with its sentence and nothing is queued; back, it catches up",
       ctx do
    server = server!(ctx)
    live!(ctx, server)
    FakeHelper.push(ctx.mac, "message", row(103))
    assert_receive {:agent_message, _first}, 10_000

    capture_log(fn -> :ok = TwoEngines.drop_session!(ctx.engines) end)

    assert_eventually(fn -> Listener.status(server.listener).class == "computer_away" end)

    assert ComputerHelper.poll_health(server.helper) == %{
             status: :away,
             detail: "studio Mac, the Mac that carries Messages, is asleep or offline."
           }

    log =
      capture_log(fn ->
        assert {:error, {:permanent, :carrier_away}} =
                 IMessage.send_message(@owner, "Reminder: water the ferns.",
                   helper: ComputerHelper,
                   server: server.helper,
                   proactive_key: "reminder-17"
                 )
      end)

    assert log =~ "asleep or offline"
    refute DeliveryError.retryable?({:permanent, :carrier_away})

    # The night's messages: more than a catch-up reads.
    FakeHelper.script(ctx.mac, "watch.subscribe", fn _params ->
      {:ok, %{"started_at_rowid" => 900, "replay_skipped" => 37}}
    end)

    capture_log(fn -> :ok = TwoEngines.reconnect!(ctx.engines) end)

    mac = ctx.mac
    assert_receive {:fake_helper_call, ^mac, "watch.subscribe", params}, 10_000
    assert params["since_rowid"] == 103
    assert params["replay"] == %{"max_rows" => 500, "max_age_s" => 86_400}

    # The owner is told how many, once, in the chat.
    assert_receive {:fake_helper_call, ^mac, "send.text", %{"text" => text} = sent}, 10_000
    assert text =~ "Fermix did not read 37 of the messages that came while studio Mac"
    assert sent["to"] == @owner
    # Nothing was kept from while the Mac was away.
    refute FakeHelper.calls(ctx.mac, "send.text") |> Enum.any?(&(&1["text"] =~ "ferns"))

    # The watch survived: a message after the return becomes a turn.
    FakeHelper.push(ctx.mac, "message", row(904, %{"text" => "good morning"}))
    assert_receive {:agent_message, %{content: "good morning"}}, 10_000
    assert ComputerHelper.poll_health(server.helper).status == :ready
    assert length(FakeHelper.calls(ctx.mac, "send.text")) == 1
  end

  test "a lost answer to a send is not known, and the message is never sent twice", ctx do
    server = server!(ctx)
    live!(ctx, server)
    test_pid = self()

    FakeHelper.script(ctx.mac, "send.text", fn _params ->
      send(test_pid, {:sending, self()})

      receive do
        :go -> {:ok, %{"disposition" => "recorded", "guid" => "g-1", "rowid" => 4200}}
      after
        30_000 -> {:ok, %{"disposition" => "recorded", "guid" => "g-1", "rowid" => 4200}}
      end
    end)

    send_task =
      Task.async(fn ->
        ComputerHelper.call(
          server.helper,
          "send.text",
          %{"to" => @owner, "text" => "On my way.", "idempotency_key" => "turn:t-9:0:text:0"},
          5_000
        )
      end)

    assert_receive {:sending, helper_pid}, 10_000

    capture_log(fn ->
      crash_admission!(ctx.engines)
      :ok = TwoEngines.drop_session!(ctx.engines)
      :ok = TwoEngines.reconnect!(ctx.engines)
    end)

    assert {:error, {:request_timeout, sentence, %{"outcome" => "unknown"}}} =
             Task.await(send_task, 15_000)

    assert sentence =~ "Fermix lost studio Mac's answer, so whether send.text to +1555…4567"
    send(helper_pid, :go)
    assert length(FakeHelper.calls(ctx.mac, "send.text")) == 1
  end

  test "policy.set never leaves the server, and the Mac refuses it too", ctx do
    server = server!(ctx)
    live!(ctx, server)

    assert {:error, {:protocol_error, sentence, %{"method" => "policy.set"}}} =
             ComputerHelper.call(
               server.helper,
               "policy.set",
               %{"owner" => "+15559990000", "handles" => ["+15559990000"]},
               5_000
             )

    assert sentence =~ "the server cannot change it"

    assert {:error, ^sentence} =
             IMessage.Capability.validate("imessage.call", %{
               "method" => "policy.set",
               "params" => %{},
               "timeout_ms" => 1_000
             })

    assert FakeHelper.calls(ctx.mac, "policy.set") == []
  end

  test "with Messages switched off at the Mac, the Mac refuses, and nothing is sent", ctx do
    server = server!(ctx)
    live!(ctx, server)
    Agent.update(ctx.engines.switch_agent, fn _on -> Switches.only([:files]) end)

    capture_log(fn ->
      assert {:error, {:permanent, :adapter_unavailable}} =
               IMessage.send_message(@owner, "Hello?",
                 helper: ComputerHelper,
                 server: server.helper
               )
    end)

    assert FakeHelper.calls(ctx.mac, "send.text") == []
    assert {:ok, %{entries: entries}} = Journal.list(Journal.dir(ctx.engines.root))

    assert %{status: "refused", refusal: "off"} =
             Enum.find(entries, &(&1.op == "imessage.send"))
  end

  test "one home has one Messages bridge: a second Mac is refused by name", ctx do
    loft = %Computer{
      device_id: "b" <> String.duplicate("7", 63),
      name: "loft Mac",
      platform: :macos,
      connected: true,
      offers: ctx.offers
    }

    {:ok, second} = Agent.start_link(fn -> [] end)
    server = server!(ctx, computers: computers(ctx, fn -> Agent.get(second, & &1) end))
    live!(ctx, server)

    log =
      capture_log(fn ->
        Agent.update(second, fn _none -> [loft] end)

        assert_eventually(fn ->
          ComputerHelper.poll_health(server.helper).detail ==
            "loft Mac offers Messages too, and one home has one Messages bridge, so Fermix " <>
              "goes on using studio Mac and refuses loft Mac."
        end)
      end)

    assert log =~ "refuses loft Mac"
    # The bridge carries on.
    FakeHelper.push(ctx.mac, "message", row(105, %{"text" => "still here"}))
    assert_receive {:agent_message, %{content: "still here"}}, 10_000
  end

  test "two Macs offering Messages from the start: none is chosen, each is named", ctx do
    loft = %Computer{
      device_id: "c" <> String.duplicate("3", 63),
      name: "loft Mac",
      platform: :macos,
      connected: true,
      offers: ctx.offers
    }

    {server, log} = with_log(fn -> server!(ctx, computers: computers(ctx, fn -> [loft] end)) end)
    assert log =~ "loft Mac and studio Mac each offer Messages"

    assert %{status: :degraded, detail: detail} = ComputerHelper.poll_health(server.helper)
    assert detail =~ "switch Messages off on all but one of them"
    assert_eventually(fn -> Listener.status(server.listener).class == "two_carriers" end)
    assert FakeHelper.calls(ctx.mac, "watch.subscribe") == []
  end

  # Its Admission dies under a run, as a crash would: the run goes with it,
  # and the restarted Admission journals it unknown (interrupted).
  defp crash_admission!(engines) do
    admission = Process.whereis(engines.admission)
    ref = Process.monitor(admission)
    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^ref, :process, ^admission, :killed}, 10_000
  end

  defp assert_eventually(fun, attempts \\ 1_000)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      # sleep: polls state that announces nothing to the test
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
