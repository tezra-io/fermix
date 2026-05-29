defmodule FermixChannels.Channels.Telegram.PollerTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Telegram.Poller

  defmodule TestAgent do
    def handle_message(_message, _server), do: :ok
  end

  setup do
    Req.Test.set_req_test_to_shared()

    Application.put_env(:fermix_channels, :telegram,
      bot_token: "test-bot-token",
      # F-02: empty allowlist now denies; poller tests need an explicit allow.
      allowed_user_ids: ["111"]
    )

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :telegram)
    end)
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
      agent: TestAgent,
      agent_server: self(),
      name: :"poller_#{System.unique_integer([:positive])}"
    ]

    opts = Keyword.merge(defaults, opts)
    pid = start_supervised!({Poller, opts})
    Req.Test.allow(:telegram_poller, self(), pid)
    pid
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

  describe "init/1" do
    test "starts with offset 0 before the startup probe runs" do
      stub_get_updates(self(), [])

      pid = start_poller()
      state = :sys.get_state(pid)
      assert state.offset == 0
    end
  end

  describe "polling" do
    test "uses a zero-timeout startup probe before regular long polling" do
      stub_get_updates_sequence(self(), [{:ok, []}, {:ok, []}])

      pid = start_poller()
      send(pid, :poll)

      assert_receive {:get_updates, startup_body}, 1_000
      assert startup_body["offset"] == 0
      assert startup_body["timeout"] == 0
      assert startup_body["allowed_updates"] == ["message"]
      assert_offset(pid, 0)

      send(pid, :poll)

      assert_receive {:get_updates, poll_body}, 1_000
      assert poll_body["offset"] == 0
      assert poll_body["timeout"] == 50
      assert poll_body["allowed_updates"] == ["message"]
    end

    test "advances offset after processing updates" do
      updates = [
        telegram_update(100, "hello"),
        telegram_update(101, "world")
      ]

      stub_get_updates_sequence(self(), [{:ok, []}, {:ok, updates}])

      pid = start_poller()
      send(pid, :poll)
      assert_receive {:get_updates, startup_body}, 1_000
      assert startup_body["timeout"] == 0

      send(pid, :poll)
      assert_receive {:get_updates, body}, 1_000
      assert body["offset"] == 0
      assert body["timeout"] == 50

      assert_offset(pid, 102)
    end

    test "keeps offset unchanged on empty regular response" do
      stub_get_updates_sequence(self(), [{:ok, []}, {:ok, []}])

      pid = start_poller()
      send(pid, :poll)
      assert_receive {:get_updates, startup_body}, 1_000
      assert startup_body["timeout"] == 0

      send(pid, :poll)
      assert_receive {:get_updates, body}, 1_000
      assert body["offset"] == 0
      assert body["timeout"] == 50

      assert_offset(pid, 0)
    end

    test "drops stale queued updates when switching from webhook to polling" do
      stale_update = telegram_update(200, "stale webhook update")
      fresh_update = telegram_update(201, "fresh polling update")
      stub_get_updates_sequence(self(), [{:ok, [stale_update]}, {:ok, [fresh_update]}])

      handler_id = attach_inbound_telemetry(self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      pid = start_poller()
      send(pid, :poll)

      assert_receive {:get_updates, startup_body}, 1_000
      assert startup_body["offset"] == 0
      assert startup_body["timeout"] == 0
      refute_receive {:telemetry, [:fermix, :channel, :message], _, _}, 100
      assert_offset(pid, 201)

      send(pid, :poll)

      assert_receive {:get_updates, poll_body}, 1_000
      assert poll_body["offset"] == 201
      assert poll_body["timeout"] == 50

      assert_receive {:telemetry, [:fermix, :channel, :message], measurements, metadata}, 1_000
      assert measurements.count == 1
      assert metadata.channel == :telegram
      assert metadata.direction == :inbound
      assert_offset(pid, 202)
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
      assert_receive {:get_updates, startup_body}, 1_000
      assert startup_body["timeout"] == 0

      send(pid, :poll)
      assert_receive {:get_updates, poll_body}, 1_000
      assert poll_body["timeout"] == 50

      assert_receive {:get_updates, retry_body}, 1_000
      assert retry_body["timeout"] == 50
      assert Process.alive?(pid)
    end
  end
end
