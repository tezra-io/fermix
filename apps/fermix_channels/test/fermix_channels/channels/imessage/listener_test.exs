defmodule FermixChannels.Channels.IMessage.ListenerTest do
  @moduledoc """
  `IMessage.Listener` against the scripted fake helper (MILESTONE_54 §7.3,
  §7.4, §9.2, §9.3): the probe gate before any subscription, the posture the
  helper derived, read from `policy.get` before subscribing, the runtime
  `policy.state` refusal, the acknowledged cursor and its generation, boot
  replay, overflow paging, admission per posture, dedupe, the bounded hand-off
  retry, and the own-posture loop breaker. The gateway is the real one; the
  agent is a capturing stand-in.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.IMessage.Listener
  alias FermixChannels.Test.IMessageFakeHelper, as: FakeHelper
  alias FermixTestSupport.SafeRm

  @owner "+15551234567"
  @guest "guest@example.com"
  @generation %{"inode" => 42, "birth_time" => "2026-09-01T00:00:00Z"}
  @recipients %{owner: @owner, handles: [@owner, @guest]}
  @dedicated Map.put(@recipients, :posture, :dedicated_account)
  @own %{posture: :own_account, owner: @owner, handles: [@owner]}

  # Records every hand-off for the test and answers from a script (`:ok` once
  # the script runs out), the way `Gateway.Queue.handle_message/2` would.
  defmodule CapturingAgent do
    @moduledoc false
    def handle_message(message, agent) do
      Agent.get_and_update(agent, fn %{test_pid: pid, results: results} = state ->
        send(pid, {:agent_message, message})

        case results do
          [] -> {:ok, state}
          [result | rest] -> {result, %{state | results: rest}}
        end
      end)
    end
  end

  setup do
    home = SafeRm.make_tmp_dir!("imessage-listener")
    previous = Application.get_env(:fermix_channels, :imessage)

    Application.put_env(:fermix_channels, :imessage, enabled: true, owner_user_id: @owner)

    on_exit(fn ->
      restore_env(previous)
      SafeRm.rm_rf!(home)
    end)

    fake = :"imessage_listener_fake_#{System.unique_integer([:positive])}"
    {:ok, agent} = Agent.start_link(fn -> %{test_pid: self(), results: []} end)
    test_pid = self()
    Agent.update(agent, &%{&1 | test_pid: test_pid})

    %{home: home, fake: fake, agent: agent}
  end

  defp restore_env(nil), do: Application.delete_env(:fermix_channels, :imessage)
  defp restore_env(config), do: Application.put_env(:fermix_channels, :imessage, config)

  defp start_fake(ctx, opts) do
    start_supervised!(
      {FakeHelper, Keyword.merge([name: ctx.fake, home: ctx.home, test_pid: self()], opts)},
      id: :fake_helper
    )
  end

  defp start_listener(ctx, opts \\ []) do
    listener_opts =
      Keyword.merge(
        [
          name: :"imessage_listener_#{System.unique_integer([:positive])}",
          helper: FakeHelper,
          server: ctx.fake,
          home: ctx.home,
          recipients: @recipients,
          agent: CapturingAgent,
          agent_server: ctx.agent,
          probe_retry_ms: 20,
          handoff_retry_ms: 20,
          loop_pause_ms: 100
        ],
        opts
      )

    start_supervised!({Listener, listener_opts}, id: :listener)
  end

  defp live(ctx, fake_opts \\ [], listener_opts \\ []) do
    start_fake(ctx, fake_opts)
    listener = start_listener(ctx, listener_opts)
    fake = ctx.fake
    assert_receive {:fake_helper_call, ^fake, "watch.subscribe", _params}
    assert_eventually(fn -> Listener.status(listener).phase == :live end)
    listener
  end

  defp write_cursor(home, generation, rowid) do
    dir = Path.join(home, "imessage")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "cursor"),
      Jason.encode!(%{"generation" => generation, "rowid" => rowid})
    )
  end

  defp read_cursor(home) do
    home |> Path.join("imessage/cursor") |> File.read!() |> Jason.decode!()
  end

  defp row(rowid, overrides \\ %{}) do
    Map.merge(
      %{
        "rowid" => rowid,
        "guid" => "guid-#{rowid}-#{System.unique_integer([:positive])}",
        "chat" => %{
          "rowid" => 17,
          "guid" => "any;-;#{@owner}",
          "identifier" => @owner,
          "service" => "iMessage",
          "group" => false
        },
        "sender" => %{"handle" => @owner, "service" => "iMessage", "is_me" => false},
        "date" => "2026-10-03T12:00:00Z",
        "text" => "message #{rowid}",
        "decode_error" => nil,
        "reply_to_guid" => nil,
        "attachments" => [],
        "reaction" => nil
      },
      overrides
    )
  end

  defp own_row(rowid) do
    row(rowid, %{"sender" => %{"handle" => nil, "service" => "iMessage", "is_me" => true}})
  end

  defp attach_transport_events do
    test_pid = self()
    handler_id = "imessage-listener-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :transport],
        fn _event, measurements, metadata, _config ->
          if metadata.channel == :imessage do
            send(test_pid, {:transport, self(), metadata.status, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_eventually(fun, attempts \\ 400)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  describe "admit/2 (§9.2, one function, two clauses)" do
    test "the dedicated posture admits the owner and listed guests, never itself or strangers" do
      assert Listener.admit(row(1), @dedicated) == :admit

      guest = %{"handle" => "Guest@Example.com", "service" => "iMessage", "is_me" => false}
      assert Listener.admit(row(2, %{"sender" => guest}), @dedicated) == :admit

      stranger = %{"handle" => "+15550009999", "service" => "iMessage", "is_me" => false}

      assert Listener.admit(row(3, %{"sender" => stranger}), @dedicated) ==
               {:drop, :not_in_policy}

      assert Listener.admit(own_row(4), @dedicated) == {:drop, :not_in_policy}
    end

    test "the own posture admits only the owner's own rows in the self chat" do
      assert Listener.admit(own_row(1), @own) == :admit
      assert Listener.admit(row(2), @own) == {:drop, :not_in_policy}

      other_chat = Map.put(own_row(3), "chat", %{row(3)["chat"] | "identifier" => "+15550009999"})
      assert Listener.admit(other_chat, @own) == {:drop, :not_in_policy}
    end

    test "both postures require iMessage on the handle and the chat, a direct chat, and no tapback" do
      for policy <- [@dedicated, @own] do
        base = if policy == @own, do: own_row(1), else: row(1)

        assert Listener.admit(put_in(base, ["sender", "service"], "SMS"), policy) ==
                 {:drop, :sms_not_supported}

        assert Listener.admit(put_in(base, ["chat", "service"], "SMS"), policy) ==
                 {:drop, :sms_not_supported}

        assert Listener.admit(put_in(base, ["chat", "service"], "any"), policy) ==
                 {:drop, :service_not_imessage}

        assert Listener.admit(
                 Map.put(base, "sender", Map.delete(base["sender"], "service")),
                 policy
               ) ==
                 {:drop, :service_not_imessage}

        assert Listener.admit(put_in(base, ["chat", "group"], true), policy) == {:drop, :group}

        reaction = %{"type" => 2000, "target_guid" => "x"}
        assert Listener.admit(Map.put(base, "reaction", reaction), policy) == {:drop, :reaction}
      end
    end
  end

  describe "the probe gate (§10.1)" do
    test "a closed gate opens no subscription, shows its class, and re-probes", ctx do
      attach_transport_events()
      unconfirmed = Map.put(FakeHelper.good_probe(), "policy", "unconfirmed")

      start_fake(ctx,
        responses: %{
          "probe" => [{:ok, unconfirmed}, {:ok, unconfirmed}, {:ok, FakeHelper.good_probe()}]
        }
      )

      listener = start_listener(ctx, probe_retry_ms: 100)
      fake = ctx.fake

      assert_receive {:transport, ^listener, :degraded, %{consecutive_failures: 1},
                      %{error_class: :policy_unconfirmed}}

      assert %{phase: :waiting, class: :policy_unconfirmed} = Listener.status(listener)
      assert_receive {:fake_helper_call, ^fake, "watch.subscribe", _params}
      assert_receive {:transport, ^listener, :recovered, _measurements, %{error_class: :none}}
      assert length(FakeHelper.calls(fake, "probe")) == 3
      refute_received {:transport, ^listener, :degraded, _, _}
    end

    # The owner is one of the signed-in account's own aliases: Messages on this
    # Mac speaks as the owner, which the helper refuses until own-account mode
    # is supported, so nothing is subscribed.
    test "an owner among the account's own aliases closes the gate", ctx do
      own_mac = Map.put(FakeHelper.good_probe(), "self_aliases", ["+1 555 123 4567"])
      start_fake(ctx, responses: %{"probe" => {:ok, own_mac}})

      listener = start_listener(ctx, probe_retry_ms: 60_000)

      assert_eventually(fn -> Listener.status(listener).class == :owner_is_this_mac end)
      assert %{phase: :waiting} = Listener.status(listener)
      assert FakeHelper.calls(ctx.fake, "watch.subscribe") == []
    end

    test "a helper that is down at attach waits for it to come up", ctx do
      start_fake(ctx, attach: {:down, "helper_exit 75"})
      listener = start_listener(ctx)

      assert_eventually(fn -> Listener.status(listener).phase == :helper_down end)

      # A database event from before the helper answered `initialize` has no
      # cursor to act on; only `:up` starts the watch.
      FakeHelper.push(ctx.fake, "db.state", %{"state" => "available", "class" => nil})

      FakeHelper.push(ctx.fake, "db.state", %{
        "state" => "unavailable",
        "class" => "db_unreadable"
      })

      assert Listener.status(listener).phase == :helper_down
      assert FakeHelper.calls(ctx.fake, "watch.subscribe") == []

      FakeHelper.helper_up(ctx.fake)
      fake = ctx.fake
      assert_receive {:fake_helper_call, ^fake, "watch.subscribe", %{"since_rowid" => nil}}
      assert_eventually(fn -> Listener.status(listener).phase == :live end)
    end
  end

  describe "the posture the helper derived" do
    test "is read with policy.get after the probe and before the subscription", ctx do
      start_fake(ctx, [])
      listener = start_listener(ctx)
      fake = ctx.fake

      methods =
        for _call <- 1..3 do
          assert_receive {:fake_helper_call, ^fake, method, _params}
          method
        end

      assert methods == ["probe", "policy.get", "watch.subscribe"]
      assert_eventually(fn -> Listener.status(listener).phase == :live end)

      FakeHelper.push(ctx.fake, "message", row(101))
      assert_receive {:agent_message, %{metadata: %{posture: :dedicated_account}}}
    end

    test "own_account from the helper admits the self chat, whatever the config says", ctx do
      own = Map.put(FakeHelper.good_policy(), "posture", "own_account")
      live(ctx, responses: %{"policy.get" => {:ok, own}})

      FakeHelper.push(ctx.fake, "message", row(101))
      FakeHelper.push(ctx.fake, "message", own_row(102))

      assert_receive {:agent_message,
                      %{content: "message 102", metadata: %{posture: :own_account}}}

      refute_received {:agent_message, %{content: "message 101"}}
    end

    test "a policy.get outside the protocol keeps the channel waiting", ctx do
      bad = Map.put(FakeHelper.good_policy(), "posture", "shared_account")
      start_fake(ctx, responses: %{"policy.get" => {:ok, bad}})

      log =
        capture_log(fn ->
          listener = start_listener(ctx, probe_retry_ms: 60_000)
          assert_eventually(fn -> Listener.status(listener).class == :protocol_error end)
        end)

      assert log =~ "posture"
      assert FakeHelper.calls(ctx.fake, "watch.subscribe") == []
    end
  end

  describe "policy.state (the helper's runtime refusal)" do
    test "owner_is_this_mac stops the channel, logs once and names the class", ctx do
      attach_transport_events()
      listener = live(ctx, [], probe_retry_ms: 60_000)
      own_mac = Map.put(FakeHelper.good_probe(), "self_aliases", [@owner])
      FakeHelper.script(ctx.fake, "probe", {:ok, own_mac})
      params = %{"state" => "owner_is_this_mac", "owner" => "+1555…4567"}

      log =
        capture_log(fn ->
          FakeHelper.push(ctx.fake, "policy.state", params)
          assert_eventually(fn -> Listener.status(listener).class == :owner_is_this_mac end)
          FakeHelper.push(ctx.fake, "policy.state", params)
          send(listener, :probe)
          :sys.get_state(listener)
        end)

      assert %{phase: :waiting, class: :owner_is_this_mac} = Listener.status(listener)

      assert_receive {:transport, ^listener, :degraded, _measurements,
                      %{error_class: :owner_is_this_mac}}

      assert length(Regex.scan(~r/owner_is_this_mac/, log)) == 1
      refute log =~ @owner

      FakeHelper.push(ctx.fake, "message", row(101))
      refute_receive {:agent_message, _}, 50
    end

    test "a state outside the protocol is logged and changes nothing", ctx do
      listener = live(ctx)

      log =
        capture_log(fn ->
          FakeHelper.push(ctx.fake, "policy.state", %{"state" => "teleported"})
          :sys.get_state(listener)
        end)

      assert log =~ "teleported"
      assert %{phase: :live, class: nil} = Listener.status(listener)
    end
  end

  describe "the acknowledged cursor (§7.3)" do
    test "a fresh home subscribes from now and records that row under the generation", ctx do
      live(ctx)

      assert [%{"since_rowid" => nil, "replay" => nil, "buffer_limit" => 256}] =
               FakeHelper.calls(ctx.fake, "watch.subscribe")

      assert read_cursor(ctx.home) == %{"generation" => @generation, "rowid" => 100}
      assert File.stat!(Path.join(ctx.home, "imessage")).mode |> Bitwise.band(0o777) == 0o700
    end

    test "a cursor of this generation resumes with the boot replay bounds", ctx do
      write_cursor(ctx.home, @generation, 4_000)
      live(ctx)

      assert [%{"since_rowid" => 4_000, "replay" => %{"max_rows" => 50, "max_age_s" => 600}}] =
               FakeHelper.calls(ctx.fake, "watch.subscribe")
    end

    test "a cursor of another generation resets to now with one log line", ctx do
      write_cursor(ctx.home, %{"inode" => 1, "birth_time" => "2020-01-01T00:00:00Z"}, 4_000)

      log =
        capture_log(fn ->
          live(ctx)
        end)

      assert [%{"since_rowid" => nil}] = FakeHelper.calls(ctx.fake, "watch.subscribe")
      assert length(Regex.scan(~r/cursor reset/, log)) == 1
    end

    test "rows skipped by the boot replay bound are logged once and exposed for readiness", ctx do
      write_cursor(ctx.home, @generation, 4_000)

      log =
        capture_log(fn ->
          listener =
            live(ctx,
              responses: %{
                "watch.subscribe" => {:ok, %{"started_at_rowid" => 4_090, "replay_skipped" => 7}}
              }
            )

          assert Listener.status(listener).replay_skipped == 7
        end)

      assert log =~ "7 messages from before the restart were not replayed"
    end

    test "the cursor advances only after a successful hand-off", ctx do
      listener = live(ctx)

      FakeHelper.push(ctx.fake, "message", row(101))
      assert_receive {:agent_message, %{content: "message 101", metadata: %{user_id: @owner}}}
      assert_eventually(fn -> read_cursor(ctx.home)["rowid"] == 101 end)
      assert Listener.status(listener).cursor == 101
    end

    test "a row at or below the cursor is never handed off again", ctx do
      live(ctx)

      FakeHelper.push(ctx.fake, "message", row(100))
      FakeHelper.push(ctx.fake, "message", row(102))

      assert_receive {:agent_message, %{content: "message 102"}}
      refute_received {:agent_message, %{content: "message 100"}}
    end

    test "a guid already handed off is deduplicated", ctx do
      live(ctx)
      first = row(101)

      FakeHelper.push(ctx.fake, "message", first)
      assert_receive {:agent_message, %{content: "message 101"}}

      FakeHelper.push(ctx.fake, "message", %{first | "rowid" => 102})
      FakeHelper.push(ctx.fake, "message", row(103))
      assert_receive {:agent_message, %{content: "message 103"}}
      refute_received {:agent_message, %{content: "message 101"}}
      assert_eventually(fn -> read_cursor(ctx.home)["rowid"] == 103 end)
    end
  end

  describe "a failed hand-off" do
    test "forgets the guid, keeps the cursor, and retries from it until it lands", ctx do
      Agent.update(ctx.agent, &%{&1 | results: [{:error, :queue_refused}]})
      listener = live(ctx)
      failing = row(101)

      FakeHelper.script(ctx.fake, "messages.after", [
        {:ok, %{"messages" => [failing], "has_more" => false}}
      ])

      FakeHelper.push(ctx.fake, "message", failing)

      assert_receive {:agent_message, %{content: "message 101"}}
      assert_receive {:agent_message, %{content: "message 101"}}
      assert_eventually(fn -> read_cursor(ctx.home)["rowid"] == 101 end)

      fake = ctx.fake
      assert_receive {:fake_helper_call, ^fake, "watch.unsubscribe", _params}
      assert [%{"since_rowid" => 100, "limit" => 64}] = FakeHelper.calls(fake, "messages.after")
      assert_eventually(fn -> length(FakeHelper.calls(fake, "watch.subscribe")) == 2 end)

      assert %{"since_rowid" => 101, "replay" => nil} =
               List.last(FakeHelper.calls(fake, "watch.subscribe"))

      assert_eventually(fn -> Listener.status(listener).phase == :live end)
    end

    test "gives up on one message after three attempts, loudly, and moves on", ctx do
      Agent.update(ctx.agent, &%{&1 | results: List.duplicate({:error, :poisoned}, 3)})
      live(ctx)
      failing = row(101)

      FakeHelper.script(
        ctx.fake,
        "messages.after",
        {:ok, %{"messages" => [failing], "has_more" => false}}
      )

      log =
        capture_log(fn ->
          FakeHelper.push(ctx.fake, "message", failing)
          for _attempt <- 1..3, do: assert_receive({:agent_message, %{content: "message 101"}})
          assert_eventually(fn -> read_cursor(ctx.home)["rowid"] == 101 end)
        end)

      assert log =~ "dropped after 3 failed hand-offs"
      refute_received {:agent_message, _}
    end
  end

  describe "overflow recovery (§7.3)" do
    test "pages from the acknowledged cursor until has_more is false, then re-subscribes", ctx do
      live(ctx)
      fake = ctx.fake

      FakeHelper.script(ctx.fake, "messages.after", [
        {:ok, %{"messages" => [row(101), row(102)], "has_more" => true}},
        {:ok, %{"messages" => [row(103)], "has_more" => false}}
      ])

      FakeHelper.push(ctx.fake, "watch.overflow", %{"dropped" => 40, "resume_after_rowid" => 150})

      for rowid <- 101..103 do
        content = "message #{rowid}"
        assert_receive {:agent_message, %{content: ^content}}
      end

      assert [%{"since_rowid" => 100}, %{"since_rowid" => 102}] =
               FakeHelper.calls(fake, "messages.after")

      assert_eventually(fn -> length(FakeHelper.calls(fake, "watch.subscribe")) == 2 end)

      assert %{"since_rowid" => 103, "replay" => nil} =
               List.last(FakeHelper.calls(fake, "watch.subscribe"))

      assert read_cursor(ctx.home)["rowid"] == 103
    end
  end

  describe "database and helper lifecycle" do
    test "a generation change resets the cursor to now", ctx do
      write_cursor(ctx.home, @generation, 4_000)
      listener = live(ctx)
      fake = ctx.fake

      new_generation = %{"inode" => 99, "birth_time" => "2026-10-03T00:00:00Z"}

      FakeHelper.push(fake, "db.state", %{
        "state" => "unavailable",
        "class" => "generation_changed",
        "db_generation" => new_generation
      })

      assert_eventually(fn -> Listener.status(listener).phase == :waiting end)

      FakeHelper.push(fake, "db.state", %{
        "state" => "available",
        "class" => nil,
        "db_generation" => new_generation
      })

      assert_eventually(fn -> length(FakeHelper.calls(fake, "watch.subscribe")) == 2 end)
      assert %{"since_rowid" => nil} = List.last(FakeHelper.calls(fake, "watch.subscribe"))

      # The reset cursor is written under the generation the helper named, so
      # the next boot adopts it instead of resetting a second time.
      assert_eventually(fn ->
        File.exists?(Path.join(ctx.home, "imessage/cursor")) and
          read_cursor(ctx.home)["generation"] == new_generation
      end)
    end

    test "a restarted helper is re-probed and re-subscribed from the cursor", ctx do
      listener = live(ctx)
      fake = ctx.fake

      FakeHelper.helper_down(fake, {:helper_exit, 75})
      assert_eventually(fn -> Listener.status(listener).phase == :helper_down end)

      FakeHelper.helper_up(fake)
      assert_eventually(fn -> length(FakeHelper.calls(fake, "watch.subscribe")) == 2 end)

      assert %{"since_rowid" => 100, "replay" => nil} =
               List.last(FakeHelper.calls(fake, "watch.subscribe"))
    end

    test "send.reconciled is logged with its key and disposition", ctx do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)
      listener = live(ctx)

      log =
        capture_log([level: :info], fn ->
          FakeHelper.push(ctx.fake, "send.reconciled", %{
            "idempotency_key" => "turn:t-1:0:text:0",
            "disposition" => "uncertain",
            "guid" => nil
          })

          assert_eventually(fn -> Listener.status(listener).phase == :live end)
          :sys.get_state(listener)
        end)

      assert log =~ "turn:t-1:0:text:0"
      assert log =~ "uncertain"
    end
  end

  describe "rows the gateway receives" do
    test "an SMS row from an allowed sender is refused with one log line per sender", ctx do
      live(ctx)
      sms = fn rowid -> put_in(row(rowid), ["chat", "service"], "SMS") end

      log =
        capture_log(fn ->
          FakeHelper.push(ctx.fake, "message", sms.(101))
          FakeHelper.push(ctx.fake, "message", sms.(102))
          FakeHelper.push(ctx.fake, "message", row(103))
          assert_receive {:agent_message, %{content: "message 103"}}
        end)

      assert length(Regex.scan(~r/sms_not_supported/, log)) == 1
      refute log =~ @owner
      refute_received {:agent_message, %{content: "message 101"}}
    end

    test "a row whose body could not be decoded reaches the gateway as an empty message", ctx do
      live(ctx)

      FakeHelper.push(
        ctx.fake,
        "message",
        row(101, %{"text" => nil, "decode_error" => "typedstream_truncated"})
      )

      fake = ctx.fake
      assert_receive {:fake_helper_call, ^fake, "send.text", %{"text" => text, "to" => @owner}}
      assert text =~ "looks empty"
      refute_received {:agent_message, _}
      assert_eventually(fn -> read_cursor(ctx.home)["rowid"] == 101 end)
    end

    test "an image is fetched into the inbox, handed to the turn, and deleted after", ctx do
      live(ctx)
      inbox = Path.join([ctx.home, "imessage", "inbox", "IMG-GUID"])
      File.mkdir_p!(inbox)
      image = Path.join(inbox, "0-photo.png")
      File.write!(image, "png-bytes")

      FakeHelper.script(
        ctx.fake,
        "attachment.fetch",
        {:ok, %{"path" => image, "mime" => "image/png", "bytes" => 9}}
      )

      attachment = %{
        "index" => 0,
        "guid" => "at0",
        "name" => "photo.png",
        "mime" => "image/png",
        "bytes" => 9
      }

      FakeHelper.push(
        ctx.fake,
        "message",
        row(101, %{"guid" => "IMG-GUID", "text" => "look", "attachments" => [attachment]})
      )

      assert_receive {:agent_message,
                      %{content: "look", media_parts: [%{type: :image, data: "png-bytes"}]}}

      refute File.exists?(image)
    end
  end

  describe "the own-posture loop breaker (§9.3)" do
    test "more than six admitted rows in a minute pause the chat, once, and it recovers", ctx do
      attach_transport_events()
      own = Map.put(FakeHelper.good_policy(), "posture", "own_account")
      listener = live(ctx, responses: %{"policy.get" => {:ok, own}})

      log =
        capture_log(fn ->
          for rowid <- 101..107, do: FakeHelper.push(ctx.fake, "message", own_row(rowid))
          for _turn <- 1..6, do: assert_receive({:agent_message, %{metadata: %{user_id: @owner}}})

          assert_receive {:transport, ^listener, :degraded, _measurements,
                          %{error_class: :loop_suspected}}

          assert_receive {:transport, ^listener, :recovered, _measurements,
                          %{error_class: :none}},
                         2_000
        end)

      refute_received {:agent_message, _}
      assert length(Regex.scan(~r/loop suspected/, log)) == 1
      assert_eventually(fn -> read_cursor(ctx.home)["rowid"] == 107 end)

      FakeHelper.push(ctx.fake, "message", own_row(108))
      assert_receive {:agent_message, %{content: "message 108"}}
    end
  end
end
