# Telegram Polling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add long-polling mode to Telegram channel so the bot works without a public HTTPS URL.

**Architecture:** A `Telegram.Poller` GenServer long-polls Telegram's `getUpdates` API, reusing existing message parsing and agent dispatch. Config toggle (`mode: :polling` vs `:webhook`) determines whether the poller starts.

**Startup/backlog policy:** The poller starts with a zero-timeout startup probe that advances the
Telegram `offset` past any already-queued updates without processing them. This is also the
webhook-to-polling transition rule: stale queued updates are dropped, and only updates that arrive
after the startup probe enter the regular long-poll loop.

**Tech Stack:** Elixir, OTP GenServer, Req HTTP client, ExUnit

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `apps/fermix_channels/lib/fermix_channels/telegram/poller.ex` | GenServer that long-polls getUpdates |
| Create | `apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs` | Poller unit tests |
| Modify | `apps/fermix_channels/lib/fermix_channels/telegram.ex` | Extract `parse_update/2` from private `parse_message/1` for poller reuse |
| Modify | `apps/fermix_channels/lib/fermix_channels/application.ex` | Conditionally start poller |
| Modify | `config/config.exs` | Add `mode: :webhook` default |
| Modify | `config/test.exs` | Add `mode: :webhook` |
| Modify | `config/runtime.exs` | Parse `TELEGRAM_MODE` env var |

---

### Task 1: Config — add `mode` key

**Files:**
- Modify: `config/config.exs:51-56`
- Modify: `config/test.exs:21-27`
- Modify: `config/runtime.exs:52-57,78-83`

- [ ] **Step 1: Add `mode: :webhook` to `config/config.exs`**

In `config/config.exs`, change the telegram config block:

```elixir
config :fermix_channels,
  telegram: [
    enabled: true,
    mode: :webhook,
    webhook_path: "/webhook/telegram",
    allowed_user_ids: []
  ]
```

- [ ] **Step 2: Add `mode: :webhook` to `config/test.exs`**

```elixir
config :fermix_channels,
  telegram: [
    enabled: false,
    mode: :webhook,
    webhook_path: "/webhook/telegram",
    bot_token: "test-token",
    allowed_user_ids: []
  ]
```

- [ ] **Step 3: Parse `TELEGRAM_MODE` env var in `config/runtime.exs`**

In both the `prod` and `else` branches, add `mode` to `merged_telegram`. Before the `merged_telegram` assignment in each branch, add:

```elixir
telegram_mode =
  case System.get_env("TELEGRAM_MODE") do
    "polling" -> :polling
    _ -> :webhook
  end
```

Then add `mode: telegram_mode` to each `Keyword.merge` call for `merged_telegram`:

Prod branch:
```elixir
merged_telegram =
  Keyword.merge(existing_telegram,
    bot_token: System.fetch_env!("TELEGRAM_BOT_TOKEN"),
    webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET"),
    allowed_user_ids: allowed_user_ids,
    mode: telegram_mode
  )
```

Non-prod branch:
```elixir
merged_telegram =
  Keyword.merge(existing_telegram,
    bot_token: System.get_env("TELEGRAM_BOT_TOKEN", ""),
    webhook_secret: System.get_env("TELEGRAM_WEBHOOK_SECRET"),
    allowed_user_ids: allowed_user_ids,
    mode: telegram_mode
  )
```

- [ ] **Step 4: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compiles with no warnings.

- [ ] **Step 5: Verify existing tests still pass**

Run: `mix test`
Expected: All tests pass, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add config/config.exs config/test.exs config/runtime.exs
git commit -m "feat: add telegram mode config toggle (webhook/polling)"
```

---

### Task 2: Extract `parse_update/2` from Telegram module

The poller needs to call `parse_message/1` which is currently private. Instead of making it public, extract a `parse_update/1` function that takes a raw Telegram update map (the same shape as webhook params) and returns parsed messages. This keeps the public API clean.

**Files:**
- Modify: `apps/fermix_channels/lib/fermix_channels/telegram.ex:171-201`
- Test: `apps/fermix_channels/test/fermix_channels/telegram_test.exs`

- [ ] **Step 1: Write failing test for `parse_update/1`**

Add to `apps/fermix_channels/test/fermix_channels/telegram_test.exs`, a new describe block after the existing `parse_webhook/1` block:

```elixir
describe "parse_update/1" do
  test "parses a message update into standard message" do
    update = %{
      "message" => %{
        "message_id" => 42,
        "text" => "hello",
        "chat" => %{"id" => 123},
        "from" => %{"id" => 111, "username" => "alice"}
      }
    }

    assert {:ok, [msg]} = Telegram.parse_update(update)
    assert msg.content == "hello"
    assert msg.sender == "alice"
    assert msg.chat_id == "123"
  end

  test "returns {:ok, []} for unauthorized user" do
    Application.put_env(:fermix_channels, :telegram,
      bot_token: "test-bot-token",
      webhook_secret: "test-secret",
      allowed_user_ids: [999]
    )

    update = %{
      "message" => %{
        "message_id" => 1,
        "text" => "hi",
        "chat" => %{"id" => 1},
        "from" => %{"id" => 111, "username" => "alice"}
      }
    }

    assert {:ok, []} = Telegram.parse_update(update)
  end

  test "returns {:ok, []} for non-message updates" do
    assert {:ok, []} = Telegram.parse_update(%{"callback_query" => %{}})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/fermix_channels/test/fermix_channels/telegram_test.exs --trace 2>&1 | grep -E "(parse_update|FAIL|undefined)"`
Expected: FAIL — `Telegram.parse_update/1 is undefined`

- [ ] **Step 3: Implement `parse_update/1`**

In `apps/fermix_channels/lib/fermix_channels/telegram.ex`, add a public function after `build_agent_messages/1` (line 128):

```elixir
@doc "Parse a raw Telegram update into standard messages. Used by both webhook and poller."
@spec parse_update(map()) :: {:ok, [FermixChannels.Channel.message()]} | {:error, term()}
def parse_update(update) do
  cond do
    Map.has_key?(update, "message") ->
      parse_message(update["message"])

    Map.has_key?(update, "edited_message") ->
      parse_message(update["edited_message"])

    true ->
      {:ok, []}
  end
end
```

Then refactor `parse_webhook/1` to delegate to `parse_update/1`:

```elixir
@impl true
@spec parse_webhook(map()) :: {:ok, [FermixChannels.Channel.message()]} | {:error, term()}
def parse_webhook(params) do
  with {:ok, messages} when messages != [] <- parse_update(params) do
    :telemetry.execute(
      [:fermix, :channel, :message],
      %{count: length(messages)},
      %{channel: :telegram, direction: :inbound}
    )

    {:ok, messages}
  end
end
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `mix test apps/fermix_channels/test/fermix_channels/telegram_test.exs`
Expected: All tests pass (existing + 3 new), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add apps/fermix_channels/lib/fermix_channels/telegram.ex apps/fermix_channels/test/fermix_channels/telegram_test.exs
git commit -m "refactor: extract parse_update/1 for poller reuse"
```

---

### Task 3: Create `Telegram.Poller` GenServer

**Files:**
- Create: `apps/fermix_channels/lib/fermix_channels/telegram/poller.ex`
- Create: `apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs`

- [ ] **Step 1: Write failing tests**

Create `apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs`:

```elixir
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

  describe "init/1" do
    test "starts with offset 0" do
      stub_get_updates(self(), [])

      {:ok, pid} = Poller.start_link(req_options: [plug: {Req.Test, :telegram_poller}], poll_interval: :manual)
      state = :sys.get_state(pid)
      assert state.offset == 0

      GenServer.stop(pid)
    end
  end

  describe "polling" do
    test "sends getUpdates with correct offset and timeout" do
      stub_get_updates(self(), [])

      {:ok, pid} = Poller.start_link(req_options: [plug: {Req.Test, :telegram_poller}], poll_interval: :manual)
      send(pid, :poll)

      assert_receive {:get_updates, body}, 1_000
      assert body["offset"] == 0
      assert body["timeout"] == 30
      assert body["allowed_updates"] == ["message"]

      GenServer.stop(pid)
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

      {:ok, pid} = Poller.start_link(req_options: [plug: {Req.Test, :telegram_poller}], poll_interval: :manual)
      send(pid, :poll)

      assert_receive {:get_updates, _body}, 1_000

      # Allow processing time
      Process.sleep(100)
      state = :sys.get_state(pid)
      assert state.offset == 102

      GenServer.stop(pid)
    end

    test "retries with backoff on error" do
      stub_get_updates_error(500, %{"ok" => false})

      {:ok, pid} = Poller.start_link(
        req_options: [plug: {Req.Test, :telegram_poller}],
        poll_interval: :manual,
        error_backoff_ms: 50
      )

      send(pid, :poll)
      Process.sleep(100)

      # Should still be alive after error
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs`
Expected: FAIL — `FermixChannels.Telegram.Poller` module not found.

- [ ] **Step 3: Implement `Telegram.Poller` GenServer**

Create `apps/fermix_channels/lib/fermix_channels/telegram/poller.ex`:

```elixir
defmodule FermixChannels.Telegram.Poller do
  @moduledoc """
  Long-polls Telegram's getUpdates API for incoming messages.

  Runs as a GenServer under supervision. Reuses Telegram.parse_update/1
  for message parsing and MainAgent.handle_message/1 for dispatch.
  """

  use GenServer

  require Logger

  alias FermixChannels.Telegram
  alias FermixCore.Agents.MainAgent

  @bot_api_base "https://api.telegram.org"
  @default_poll_timeout 30
  @default_error_backoff_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      offset: 0,
      req_options: Keyword.get(opts, :req_options, []),
      poll_interval: Keyword.get(opts, :poll_interval, :immediate),
      error_backoff_ms: Keyword.get(opts, :error_backoff_ms, @default_error_backoff_ms)
    }

    if state.poll_interval != :manual do
      send(self(), :poll)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case do_poll(state) do
      {:ok, updates, state} ->
        process_updates(updates)
        state = advance_offset(state, updates)

        if state.poll_interval != :manual do
          send(self(), :poll)
        end

        {:noreply, state}

      {:error, reason, state} ->
        Logger.error("Telegram poller error: #{inspect(reason)}")
        Process.send_after(self(), :poll, state.error_backoff_ms)
        {:noreply, state}
    end
  end

  defp do_poll(state) do
    with {:ok, token} <- get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/getUpdates"

      body = %{
        offset: state.offset,
        timeout: @default_poll_timeout,
        allowed_updates: ["message"]
      }

      result =
        Req.new(url: url, method: :post, json: body, receive_timeout: 35_000)
        |> Req.merge(state.req_options)
        |> Req.request()

      case result do
        {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} ->
          {:ok, updates, state}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, "Telegram API error #{status}: #{inspect(resp_body)}", state}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp process_updates(updates) do
    Enum.each(updates, fn update ->
      case Telegram.parse_update(update) do
        {:ok, messages} when messages != [] ->
          :telemetry.execute(
            [:fermix, :channel, :message],
            %{count: length(messages)},
            %{channel: :telegram, direction: :inbound}
          )

          messages
          |> Telegram.build_agent_messages()
          |> Enum.each(&MainAgent.handle_message/1)

        _ ->
          :ok
      end
    end)
  end

  defp advance_offset(state, []) do
    state
  end

  defp advance_offset(state, updates) do
    max_id =
      updates
      |> Enum.map(&(&1["update_id"]))
      |> Enum.max()

    %{state | offset: max_id + 1}
  end

  defp get_bot_token do
    with {:ok, config} <- FermixCore.Config.channel(:telegram),
         {:ok, token} when is_binary(token) and token != "" <- Keyword.fetch(config, :bot_token) do
      {:ok, token}
    else
      _ -> {:error, :not_configured}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs`
Expected: All tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add apps/fermix_channels/lib/fermix_channels/telegram/poller.ex apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs
git commit -m "feat: add Telegram.Poller GenServer for long-polling mode"
```

---

### Task 4: Conditional poller startup in Application supervisor

**Files:**
- Modify: `apps/fermix_channels/lib/fermix_channels/application.ex`
- Test: `apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs`

- [ ] **Step 1: Write failing test for conditional startup**

Add to `apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs`:

```elixir
describe "application startup" do
  test "poller does not start when mode is :webhook" do
    Application.put_env(:fermix_channels, :telegram,
      bot_token: "test-bot-token",
      mode: :webhook,
      enabled: true
    )

    # Poller should not be registered
    assert Process.whereis(FermixChannels.Telegram.Poller) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it passes (baseline — poller isn't started yet)**

Run: `mix test apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs --trace 2>&1 | grep "application startup"`
Expected: PASS (the poller is not started in webhook mode, which is the current behavior).

This test serves as a regression guard. Now implement the conditional startup.

- [ ] **Step 3: Implement conditional startup in `application.ex`**

Replace the contents of `apps/fermix_channels/lib/fermix_channels/application.ex`:

```elixir
defmodule FermixChannels.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = polling_children()
    opts = [strategy: :one_for_one, name: FermixChannels.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp polling_children do
    config = Application.get_env(:fermix_channels, :telegram, [])

    if config[:mode] == :polling and config[:enabled] != false do
      [{FermixChannels.Telegram.Poller, []}]
    else
      []
    end
  end
end
```

- [ ] **Step 4: Run full test suite**

Run: `mix test`
Expected: All tests pass, 0 failures. Poller does NOT auto-start in test env (mode is `:webhook` in test.exs).

- [ ] **Step 5: Commit**

```bash
git add apps/fermix_channels/lib/fermix_channels/application.ex apps/fermix_channels/test/fermix_channels/telegram/poller_test.exs
git commit -m "feat: conditionally start Telegram poller based on mode config"
```

---

### Task 5: Full integration verification

- [ ] **Step 1: Run full test suite**

Run: `mix test`
Expected: All tests pass across all umbrella apps, 0 failures.

- [ ] **Step 2: Run quality gate**

Run: `mix quality`
Expected: All checks pass (format, compile warnings, credo, dialyzer, test).

- [ ] **Step 3: Manual smoke test with polling mode**

```bash
TELEGRAM_MODE=polling TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN OPENAI_API_KEY=$OPENAI_API_KEY TELEGRAM_ALLOWED_USER_IDS=$TELEGRAM_ALLOWED_USER_IDS mix phx.server
```

Expected: Server starts, logs show poller connecting to Telegram. Send a message to your bot in Telegram — it should respond.

- [ ] **Step 4: Commit any fixes**

If any fixes were needed, commit them.
