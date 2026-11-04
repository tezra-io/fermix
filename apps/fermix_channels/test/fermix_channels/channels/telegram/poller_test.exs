defmodule FermixChannels.Channels.Telegram.PollerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.Telegram.Poller
  alias FermixChannels.Gateway.AlbumBuffer
  alias FermixChannels.Gateway.Idempotency
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  setup do
    Req.Test.set_req_test_to_shared()
    put_bot_token("123456789:test-bot-token")

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :telegram)
    end)
  end

  # A real token's part before its colon is the bot's id.
  defp put_bot_token(token) do
    Application.put_env(:fermix_channels, :telegram,
      bot_token: token,
      # F-02: empty allowlist now denies; poller tests need an explicit allow.
      allowed_user_ids: ["111"]
    )
  end

  defp stub_get_updates(test_pid, updates) do
    stub_get_updates_sequence(test_pid, [{:ok, updates}])
  end

  defp stub_get_updates_sequence(test_pid, responses) do
    {:ok, response_server} =
      Agent.start_link(fn ->
        case responses do
          [] -> [{:ok, []}]
          _ -> responses
        end
      end)

    Req.Test.stub(:telegram_poller, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      send(test_pid, {:get_updates, decoded})

      response =
        Agent.get_and_update(response_server, fn
          [next] -> {next, [next]}
          [next | rest] -> {next, rest}
        end)

      send_get_updates_response(conn, response)
    end)
  end

  defp stub_get_updates_error(status, body) do
    Req.Test.stub(:telegram_poller, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp send_get_updates_response(conn, {:ok, updates}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => updates}))
  end

  defp send_get_updates_response(conn, {:error, status, body}) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp send_get_updates_response(conn, {:transport_error, reason}) do
    Req.Test.transport_error(conn, reason)
  end

  defp start_poller(opts \\ []) do
    defaults = [
      req_options: [plug: {Req.Test, :telegram_poller}],
      poll_interval: :manual,
      # Forward parsed messages to the test process instead of the real album
      # buffer; the poller casts AlbumBuffer.ingest/2 → {:"$gen_cast", {:ingest, msg}}.
      buffer: self(),
      name: :"poller_#{System.unique_integer([:positive])}"
    ]

    opts =
      defaults
      |> Keyword.merge(opts)
      |> Keyword.put_new_lazy(:idempotency, fn -> start_idempotency() end)

    pid = start_supervised!({Poller, opts})
    Req.Test.allow(:telegram_poller, self(), pid)
    pid
  end

  # A cache of update ids of the test's own (in this process only unless
  # `store:` names a Repo), so no test shares ids with another or with the
  # application's. `:name` lets a test replace a cache under the name its
  # poller already holds.
  defp start_idempotency(opts \\ []) do
    name = Keyword.get(opts, :name, :"poller_idempotency_#{System.unique_integer([:positive])}")

    spec =
      {Idempotency,
       name: name,
       table: :"poller_idempotency_table_#{System.unique_integer([:positive])}",
       store: Keyword.get(opts, :store, :memory)}

    start_supervised!(Supervisor.child_spec(spec, id: Keyword.get(opts, :id, name)))
    name
  end

  # A Repo on `db_path`, as a restart (or the host a home moved to) opens it.
  defp start_repo(db_path, id, enabled? \\ true) do
    name = :"poller_repo_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({Repo, name: name, enabled: enabled?, database_path: db_path}, id: id)
    )

    name
  end

  defp memory_db_path do
    dir = SafeRm.make_tmp_dir!("telegram-poller")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    Path.join(dir, "memory.db")
  end

  defp album_part(update_id, file_id) do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => update_id,
        "media_group_id" => "album-7",
        "photo" => [%{"file_id" => file_id, "file_size" => 2_000, "width" => 90, "height" => 90}],
        "chat" => %{"id" => 42},
        "from" => %{"id" => 111, "username" => "alice"}
      }
    }
  end

  defp telegram_update(update_id, text) do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => update_id,
        "text" => text,
        "chat" => %{"id" => 42},
        "from" => %{"id" => 111, "username" => "alice"}
      }
    }
  end

  defp assert_offset(pid, expected, attempts \\ 20)

  defp assert_offset(pid, expected, attempts) when attempts > 0 do
    case :sys.get_state(pid).offset do
      ^expected ->
        :ok

      _other ->
        Process.sleep(10)
        assert_offset(pid, expected, attempts - 1)
    end
  end

  defp assert_offset(pid, expected, 0) do
    flunk("expected offset #{expected}, got #{inspect(:sys.get_state(pid).offset)}")
  end

  defp attach_inbound_telemetry(test_pid) do
    handler_id = "telegram-poller-inbound-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :message],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    handler_id
  end

  defp attach_transport_telemetry(test_pid) do
    handler_id = "telegram-poller-transport-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :transport],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    handler_id
  end

  defp unique_poller_name, do: :"poller_#{System.unique_integer([:positive])}"

  # Both backoffs are pinned past the test's lifetime on purpose. Unlike the two
  # success paths, `schedule_error_retry/2` re-arms unconditionally — it does not
  # honour `poll_interval: :manual` — so an unpinned backoff lets the poller
  # free-run and makes every consecutive-failure count nondeterministic.
  defp start_escalating_poller(name, opts \\ []) do
    defaults = [
      name: name,
      degraded_after_failures: 3,
      error_backoff_ms: 60_000,
      transient_backoff_ms: 60_000
    ]

    start_poller(Keyword.merge(defaults, opts))
  end

  # One completed poll per call. The `:poll` handler runs the HTTP call inline
  # (the Req.Test plug executes in the poller process) and `:sys.get_state/1` is
  # delivered through the same mailbox, so it returns only once that poll has
  # finished. No sleeps, no timing assumptions.
  defp poll_once(pid) do
    send(pid, :poll)
    :sys.get_state(pid)
  end

  defp poll_times(pid, count) when is_integer(count) and count > 0 do
    Enum.each(1..count, fn _ -> poll_once(pid) end)
  end

  defp count_matches(text, needle), do: length(:binary.matches(text, needle))

  # The stub echoes every request to the test process and nothing consumes those
  # echoes, so an `assert_receive` can otherwise be satisfied by a poll driven
  # several lines earlier.
  defp drain_get_updates do
    receive do
      {:get_updates, _body} -> drain_get_updates()
    after
      0 -> :ok
    end
  end

  describe "init/1" do
    test "starts with offset 0, so the first poll asks for everything Telegram holds" do
      stub_get_updates(self(), [])

      pid = start_poller()
      state = :sys.get_state(pid)
      assert state.offset == 0
    end
  end

  describe "polling" do
    test "the first poll is a regular long poll from offset 0" do
      stub_get_updates_sequence(self(), [{:ok, []}])

      pid = start_poller()
      poll_once(pid)

      assert_received {:get_updates, first_body}
      assert first_body["offset"] == 0
      assert first_body["timeout"] == 50
      assert first_body["allowed_updates"] == ["message", "callback_query"]
      assert :sys.get_state(pid).offset == 0
    end

    test "advances offset after processing updates" do
      updates = [
        telegram_update(100, "hello"),
        telegram_update(101, "world")
      ]

      stub_get_updates_sequence(self(), [{:ok, updates}, {:ok, []}])

      pid = start_poller()
      send(pid, :poll)
      assert_receive {:get_updates, body}
      assert body["offset"] == 0
      assert body["timeout"] == 50

      assert_offset(pid, 102)

      send(pid, :poll)
      assert_receive {:get_updates, next_body}
      assert next_body["offset"] == 102
    end

    test "keeps offset unchanged on empty regular response" do
      stub_get_updates_sequence(self(), [{:ok, []}, {:ok, []}])

      pid = start_poller()
      send(pid, :poll)
      assert_receive {:get_updates, body}
      assert body["offset"] == 0
      assert body["timeout"] == 50

      send(pid, :poll)
      assert_receive {:get_updates, next_body}
      assert next_body["offset"] == 0

      assert_offset(pid, 0)
    end

    # Telegram keeps an update until a later call confirms it, for 24 hours:
    # what was sent while Fermix was stopped (a restart, an update, a move to
    # another host) or what a deleted webhook left behind is answered now.
    test "hands off what Telegram held when the poller started" do
      held = [telegram_update(200, "sent while stopped"), telegram_update(201, "also then")]
      stub_get_updates_sequence(self(), [{:ok, held}, {:ok, []}])

      handler_id = attach_inbound_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid = start_poller()
      poll_once(pid)

      assert_received {:get_updates, %{"offset" => 0}}
      assert_received {:"$gen_cast", {:ingest, %{content: "sent while stopped"}}}
      assert_received {:"$gen_cast", {:ingest, %{content: "also then"}}}
      assert_receive {:telemetry, [:fermix, :channel, :message], %{count: 1}, metadata}
      assert metadata == %{channel: :telegram, direction: :inbound}
      assert :sys.get_state(pid).offset == 202

      poll_once(pid)
      assert_received {:get_updates, %{"offset" => 202}}
    end

    test "retries after error" do
      stub_get_updates_error(500, %{"ok" => false})

      pid = start_poller(error_backoff_ms: 50)
      send(pid, :poll)

      Process.sleep(100)
      assert Process.alive?(pid)
    end

    test "quickly reconnects after transient long-poll transport errors" do
      stub_get_updates_sequence(self(), [
        {:ok, []},
        {:transport_error, :closed},
        {:ok, []}
      ])

      pid = start_poller(poll_interval: :manual, transient_backoff_ms: 10)
      send(pid, :poll)
      assert_receive {:get_updates, first_body}
      assert first_body["timeout"] == 50

      send(pid, :poll)
      assert_receive {:get_updates, poll_body}
      assert poll_body["timeout"] == 50

      assert_receive {:get_updates, retry_body}
      assert retry_body["timeout"] == 50
      assert Process.alive?(pid)
    end
  end

  describe "album-buffer handoff" do
    test "forwards each parsed message to the album buffer (coalescing lives there)" do
      stub_get_updates_sequence(self(), [
        {:ok, []},
        {:ok, [telegram_update(100, "hello"), telegram_update(101, "world")]}
      ])

      pid = start_poller()
      send(pid, :poll)
      assert_receive {:get_updates, _first_body}

      send(pid, :poll)
      assert_receive {:get_updates, _poll_body}
      assert_receive {:"$gen_cast", {:ingest, %{content: "hello"}}}
      assert_receive {:"$gen_cast", {:ingest, %{content: "world"}}}
      assert_offset(pid, 102)
    end
  end

  describe "callback_query (inline Approve button)" do
    test "forwards a tap as a synthesized /confirm and acks the callback" do
      test_pid = self()

      callback_update = %{
        "update_id" => 300,
        "callback_query" => %{
          "id" => "cbq-1",
          "data" => "grant:TOK98765",
          "from" => %{"id" => 111, "username" => "alice"},
          "message" => %{"message_id" => 55, "chat" => %{"id" => 42}}
        }
      }

      # Path-aware stub: getUpdates draws from the sequence; the ack endpoints
      # answer ok without consuming the sequence (they'd otherwise desync it).
      {:ok, seq} = Agent.start_link(fn -> [{:ok, []}, {:ok, [callback_update]}] end)

      Req.Test.stub(:telegram_poller, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:tg_call, conn.request_path, decoded})

        updates =
          if String.ends_with?(conn.request_path, "/getUpdates") do
            Agent.get_and_update(seq, fn
              [next] -> {next, [next]}
              [next | rest] -> {next, rest}
            end)
            |> elem(1)
          else
            []
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => updates}))
      end)

      pid = start_poller()
      send(pid, :poll)
      assert_receive {:tg_call, first_path, _}
      assert String.ends_with?(first_path, "/getUpdates")

      send(pid, :poll)

      # The tap funnels through as the synthesized /confirm inbound message.
      assert_receive {:"$gen_cast", {:ingest, %{content: "/confirm TOK98765", chat_id: "42"}}}
      # ...and the poller clears the spinner and strips the used button.
      assert_receive {:tg_call, "/bot123456789:test-bot-token/answerCallbackQuery", ack}
      assert ack["callback_query_id"] == "cbq-1"
      assert_receive {:tg_call, "/bot123456789:test-bot-token/editMessageReplyMarkup", edit}
      assert edit["message_id"] == 55

      assert_offset(pid, 301)
    end
  end

  describe "recorded update ids" do
    test "an update sent again is not handed off twice" do
      stub_get_updates_sequence(self(), [
        {:ok, [telegram_update(100, "hello")]},
        {:ok, [telegram_update(100, "hello"), telegram_update(101, "world")]}
      ])

      pid = start_poller()
      poll_once(pid)
      assert_received {:"$gen_cast", {:ingest, %{content: "hello"}}}

      poll_once(pid)
      assert_received {:"$gen_cast", {:ingest, %{content: "world"}}}
      refute_received {:"$gen_cast", {:ingest, _message}}
      assert :sys.get_state(pid).offset == 102
    end

    # The batch handled last before a stop is sent again, because only the
    # next call confirms it. A fresh Repo and cache on the same memory.db are
    # what a restart starts with, and what the host a home moved to opens.
    test "an update handled before a restart is not handed off again after it" do
      db_path = memory_db_path()
      repo = start_repo(db_path, :repo_before)
      cache = start_idempotency(store: {:repo, repo}, id: :cache_before)

      stub_get_updates_sequence(self(), [{:ok, [telegram_update(100, "before the stop")]}])
      start_poller(idempotency: cache) |> poll_once()
      assert_received {:"$gen_cast", {:ingest, %{content: "before the stop"}}}

      stop_supervised!(Poller)
      :ok = stop_supervised(:cache_before)
      :ok = stop_supervised(:repo_before)
      repo = start_repo(db_path, :repo_after)
      cache = start_idempotency(store: {:repo, repo}, id: :cache_after)

      stub_get_updates_sequence(self(), [
        {:ok, [telegram_update(100, "before the stop"), telegram_update(101, "while stopped")]}
      ])

      second = start_poller(idempotency: cache)
      poll_once(second)

      assert_received {:"$gen_cast", {:ingest, %{content: "while stopped"}}}
      refute_received {:"$gen_cast", {:ingest, _message}}
      assert :sys.get_state(second).offset == 102
    end

    # Telegram numbers updates per bot: a token for another bot starts a
    # count of its own, which may pass the same numbers.
    test "an update id is recorded per bot" do
      cache = start_idempotency()
      stub_get_updates_sequence(self(), [{:ok, [telegram_update(100, "to the first bot")]}])
      start_poller(idempotency: cache) |> poll_once()
      assert_received {:"$gen_cast", {:ingest, %{content: "to the first bot"}}}
      stop_supervised!(Poller)

      put_bot_token("987654321:another-bot-token")
      stub_get_updates_sequence(self(), [{:ok, [telegram_update(100, "to the second bot")]}])
      start_poller(idempotency: cache) |> poll_once()
      assert_received {:"$gen_cast", {:ingest, %{content: "to the second bot"}}}
    end

    test "the parts of an album coalesce, and a part sent again is not added twice" do
      test_pid = self()
      cache = start_idempotency()

      buffer =
        start_supervised!(
          {AlbumBuffer,
           channel: Telegram,
           name: :"album_buffer_#{System.unique_integer([:positive])}",
           debounce_ms: 60_000,
           max_parts: 2,
           dispatch: fn messages, _opts ->
             send(test_pid, {:dispatched, messages})
             :ok
           end}
        )

      stub_get_updates_sequence(self(), [{:ok, [album_part(300, "photo-a")]}])
      start_poller(buffer: buffer, idempotency: cache) |> poll_once()
      stop_supervised!(Poller)

      # After the poller restarts, the first part comes again, beside the second.
      stub_get_updates_sequence(self(), [
        {:ok, [album_part(300, "photo-a"), album_part(301, "photo-b")]}
      ])

      start_poller(buffer: buffer, idempotency: cache) |> poll_once()

      assert_receive {:dispatched, [album]}
      assert Enum.map(album.attachments, & &1.file_id) == ["photo-a", "photo-b"]
      # Every cast the buffer was sent is handled once this call returns.
      :sys.get_state(buffer)
      refute_received {:dispatched, _messages}
    end

    test "an update the store cannot record is not handed off, and is asked for again" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      # A Repo that is turned off answers every claim with an error.
      off = start_repo(memory_db_path(), :repo_off, false)
      cache = start_idempotency(store: {:repo, off}, id: :cache_off)

      stub_get_updates_sequence(self(), [
        {:ok, [telegram_update(100, "hello"), telegram_update(101, "world")]}
      ])

      pid = start_escalating_poller(name, idempotency: cache)
      log = capture_log(fn -> poll_once(pid) end)

      assert_received {:get_updates, %{"offset" => 0}}
      refute_received {:"$gen_cast", {:ingest, _message}}
      assert %{offset: 0, consecutive_failures: 1} = :sys.get_state(pid)
      assert log =~ "could not be recorded in memory.db"
      assert log =~ "Telegram poller update record error"

      # Once the store answers, the same updates are asked for and handed off.
      :ok = stop_supervised(:cache_off)
      start_idempotency(name: cache, id: :cache_on)
      poll_once(pid)

      assert_received {:get_updates, %{"offset" => 0}}
      assert_received {:"$gen_cast", {:ingest, %{content: "hello"}}}
      assert_received {:"$gen_cast", {:ingest, %{content: "world"}}}
      assert %{offset: 102, consecutive_failures: 0} = :sys.get_state(pid)
    end
  end

  describe "failure escalation" do
    test "counts consecutive failures and publishes degraded once past the threshold" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      stub_get_updates_sequence(self(), [{:ok, []}, {:transport_error, :timeout}])
      pid = start_escalating_poller(name)

      # The first poll answers, so the poller starts from a clean slate.
      poll_once(pid)
      assert Poller.poll_health(name) == %{status: :polling, consecutive_failures: 0, since: nil}

      # Below the threshold the counter climbs but nothing is published: a
      # persistent_term write per failure would rebuild the 27,394-write problem.
      poll_once(pid)
      assert :sys.get_state(pid).consecutive_failures == 1
      assert Poller.poll_health(name) == %{status: :polling, consecutive_failures: 0, since: nil}

      poll_times(pid, 2)

      assert %{status: :degraded, consecutive_failures: 3, since: %DateTime{}} =
               Poller.poll_health(name)
    end

    test "a successful poll clears the counter and leaves degraded" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      stub_get_updates_sequence(self(), [
        {:ok, []},
        {:transport_error, :timeout},
        {:transport_error, :timeout},
        {:transport_error, :timeout},
        {:ok, []}
      ])

      pid = start_escalating_poller(name)

      poll_times(pid, 4)
      assert %{status: :degraded, consecutive_failures: 3} = Poller.poll_health(name)

      poll_once(pid)
      assert :sys.get_state(pid).consecutive_failures == 0
      assert Poller.poll_health(name) == %{status: :polling, consecutive_failures: 0, since: nil}
    end

    test "a poller whose first poll never answers escalates" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      # A poller that never gets one answer must still escalate, otherwise the
      # one failure mode that blocks every message is silent.
      stub_get_updates_sequence(self(), [{:transport_error, :timeout}])
      pid = start_escalating_poller(name)

      poll_times(pid, 3)

      assert :sys.get_state(pid).offset == 0
      assert %{status: :degraded, consecutive_failures: 3} = Poller.poll_health(name)
    end

    test "logs once on entering degraded instead of once per attempt" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      stub_get_updates_sequence(self(), [{:ok, []}, {:transport_error, :timeout}])
      pid = start_escalating_poller(name)
      poll_once(pid)

      log = capture_log(fn -> poll_times(pid, 20) end)

      assert count_matches(log, "poller degraded after") == 1
      assert log =~ "polling continues"
      # 20 failures, 3 of them below the threshold, must not produce 20 lines.
      assert count_matches(log, "Telegram poller") <= 3
    end

    test "emits the transport telemetry event once on the degraded transition" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      handler_id = attach_transport_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      stub_get_updates_sequence(self(), [{:ok, []}, {:error, 502, %{"ok" => false}}])
      pid = start_escalating_poller(name)
      poll_once(pid)

      poll_times(pid, 2)
      refute_receive {:telemetry, [:fermix, :channel, :transport], _, _}, 100

      poll_once(pid)

      assert_receive {:telemetry, [:fermix, :channel, :transport], measurements, metadata}
      assert measurements == %{count: 1, consecutive_failures: 3}
      assert metadata == %{channel: :telegram, status: :degraded, error_class: :api_error}

      # Staying degraded must not re-emit; that would rebuild the log problem in
      # telemetry.
      poll_times(pid, 5)
      refute_receive {:telemetry, [:fermix, :channel, :transport], _, _}, 100
    end

    test "emits a recovered transport event on the first success after degrading" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      handler_id = attach_transport_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      stub_get_updates_sequence(self(), [
        {:ok, []},
        {:transport_error, :timeout},
        {:transport_error, :timeout},
        {:transport_error, :timeout},
        {:ok, []}
      ])

      pid = start_escalating_poller(name)
      poll_times(pid, 4)
      assert_receive {:telemetry, [:fermix, :channel, :transport], _, %{status: :degraded}}
      poll_once(pid)

      assert_receive {:telemetry, [:fermix, :channel, :transport], measurements, metadata}
      assert measurements == %{count: 1, consecutive_failures: 3}
      assert metadata == %{channel: :telegram, status: :recovered, error_class: :none}
    end

    test "re-logs while degraded only after the interval elapses" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      stub_get_updates_sequence(self(), [{:ok, []}, {:transport_error, :timeout}])
      pid = start_escalating_poller(name, degraded_log_interval_ms: 0)
      poll_once(pid)

      log = capture_log(fn -> poll_times(pid, 6) end)

      assert count_matches(log, "poller degraded after") == 1
      assert count_matches(log, "still degraded after") >= 1
    end

    test "keeps polling on its own timer after going degraded" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      stub_get_updates_sequence(self(), [{:ok, []}, {:transport_error, :timeout}])
      # A short backoff so the poller re-arms within the test: the property here
      # is that a DEGRADED poller keeps polling on its OWN timer. Feeding it
      # `:poll` by hand would only prove the test can send a message.
      pid = start_escalating_poller(name, transient_backoff_ms: 5)
      poll_once(pid)
      poll_times(pid, 4)

      assert %{status: :degraded} = Poller.poll_health(name)

      # The stub echoes every request, so the mailbox holds the polls already
      # driven above; an assertion that matched one of those would pass even if
      # the poller had stopped re-arming entirely.
      drain_get_updates()

      # Escalation is bounded; the poll loop is not. A degraded poller that
      # stopped re-arming could never observe its own recovery.
      assert_receive {:get_updates, _body}
      assert Process.alive?(pid)
    end

    test "a restarted poller does not inherit a stale degraded posture" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      stub_get_updates_sequence(self(), [{:ok, []}, {:transport_error, :timeout}])
      first = start_escalating_poller(name)
      poll_once(first)
      poll_times(first, 3)
      assert %{status: :degraded} = Poller.poll_health(name)

      # The published posture is VM-scoped but the counter is process-scoped, so
      # a crash while degraded must not leave a red /health nothing can clear.
      stop_supervised!(Poller)
      Process.exit(first, :kill)
      refute Process.alive?(first)

      stub_get_updates_sequence(self(), [{:ok, []}])
      second = start_escalating_poller(name)
      poll_once(second)

      assert %{status: :polling, consecutive_failures: 0} = Poller.poll_health(name)
    end

    test "no published health at all means no poller, never a healthy one" do
      # A fabricated healthy default would report a channel with no poller as
      # fine — the exact blindness this change exists to remove.
      assert Poller.poll_health(unique_poller_name()) == nil
    end
  end

  describe "poll error logging" do
    test "the non-transient error log carries the elapsed time" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      stub_get_updates_sequence(self(), [{:ok, []}, {:error, 502, %{"ok" => false}}])
      pid = start_escalating_poller(name)
      poll_once(pid)

      log = capture_log(fn -> poll_once(pid) end)

      assert log =~ "Telegram poller poll error"
      assert_elapsed_ms(log)
    end

    test "the transient reconnect log carries the elapsed time" do
      name = unique_poller_name()
      on_exit(fn -> Poller.forget_poll_health(name) end)

      stub_get_updates_sequence(self(), [{:ok, []}, {:transport_error, :closed}])
      pid = start_escalating_poller(name)
      poll_once(pid)

      log = capture_log(fn -> poll_once(pid) end)

      assert log =~ "reconnecting after"
      assert_elapsed_ms(log)
    end
  end

  # Presence and shape only. Asserting a magnitude would be a timing-dependent
  # flake, and a stub that slept to make one true would be worse.
  defp assert_elapsed_ms(log) do
    assert [captured] = Regex.run(~r/elapsed_ms=(\d+)/, log, capture: :all_but_first)
    assert String.to_integer(captured) >= 0
  end
end
