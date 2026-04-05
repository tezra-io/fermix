defmodule FermixChannels.Telegram.PollerTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Telegram.Poller

  setup do
    Application.put_env(:fermix_channels, :telegram,
      bot_token: "test-bot-token",
      webhook_secret: "test-secret",
      allowed_user_ids: []
    )

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :telegram)
    end)
  end

  defp stub_get_updates(test_pid, updates) do
    Req.Test.stub(:telegram_poller, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      send(test_pid, {:get_updates, decoded})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true, "result" => updates}))
    end)
  end

  defp stub_get_updates_error(status, body) do
    Req.Test.stub(:telegram_poller, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp start_poller(opts \\ []) do
    defaults = [
      req_options: [plug: {Req.Test, :telegram_poller}],
      poll_interval: :manual,
      name: :"poller_#{System.unique_integer([:positive])}"
    ]

    opts = Keyword.merge(defaults, opts)
    pid = start_supervised!({Poller, opts})
    Req.Test.allow(:telegram_poller, self(), pid)
    pid
  end

  describe "init/1" do
    test "starts with offset 0" do
      stub_get_updates(self(), [])

      pid = start_poller()
      state = :sys.get_state(pid)
      assert state.offset == 0
    end
  end

  describe "polling" do
    test "sends getUpdates with correct offset and timeout" do
      stub_get_updates(self(), [])

      pid = start_poller()
      send(pid, :poll)

      assert_receive {:get_updates, body}, 1_000
      assert body["offset"] == 0
      assert body["timeout"] == 30
      assert body["allowed_updates"] == ["message"]
    end

    test "advances offset after processing updates" do
      updates = [
        %{
          "update_id" => 100,
          "message" => %{
            "message_id" => 1,
            "text" => "hello",
            "chat" => %{"id" => 42},
            "from" => %{"id" => 111, "username" => "alice"}
          }
        },
        %{
          "update_id" => 101,
          "message" => %{
            "message_id" => 2,
            "text" => "world",
            "chat" => %{"id" => 42},
            "from" => %{"id" => 111, "username" => "alice"}
          }
        }
      ]

      stub_get_updates(self(), updates)

      pid = start_poller()
      send(pid, :poll)

      assert_receive {:get_updates, _body}, 1_000
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.offset == 102
    end

    test "keeps offset unchanged on empty response" do
      stub_get_updates(self(), [])

      pid = start_poller()
      send(pid, :poll)

      assert_receive {:get_updates, _body}, 1_000
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.offset == 0
    end

    test "retries after error" do
      stub_get_updates_error(500, %{"ok" => false})

      pid = start_poller(error_backoff_ms: 50)
      send(pid, :poll)

      Process.sleep(100)
      assert Process.alive?(pid)
    end
  end
end
