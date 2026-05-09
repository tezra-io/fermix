# Fermix Local Chat CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class local `fermix ask` / `fermix chat` command that sends one prompt to the running Fermix daemon and returns the live `MainAgent` response.

**Architecture:** Keep the standalone CLI as a thin daemon-socket client. The daemon is already inside the live OTP runtime, so it handles an `agent_message` socket method and invokes the existing local CLI channel path in `fermix_channels`. To avoid a compile-time app cycle (`fermix_channels` depends on `fermix_core`), `fermix_core` calls the channel bridge through a runtime-configured module and `apply/3`.

**Tech Stack:** Elixir umbrella, existing daemon Unix socket protocol, `FermixChannels.CLI`, `FermixChannels.Dispatcher`, `Jason`, ExUnit.

**Non-goals:** No interactive REPL, no browser `/chat` LiveView, no second runtime, no commits unless explicitly requested.

---

## Review-Driven Scope

This plan intentionally reuses the existing local channel instead of duplicating it.

- `FermixChannels.CLI.parse_input/2` remains the canonical builder for local CLI `Message.t()` values.
- `FermixChannels.Dispatcher.dispatch/2` remains the only place that normalizes channel messages into `MainAgent` messages.
- The only new channel behavior is a sync capture mode for local daemon calls.
- `fermix_core` does not directly alias or call `FermixChannels.CLI`; it uses a configurable bridge module so app dependency direction stays clean.

Daemon posture change:

- Existing daemon methods are read-only except `shutdown`.
- `agent_message` is an explicit local operator action that can trigger an LLM call and agent tools.
- The trust boundary remains the existing `0600` Unix domain socket under `FERMIX_HOME`.
- No extra confirmation is added because the command itself is the operator confirmation: `fermix ask ...`.

---

## File Structure

- Modify `apps/fermix_channels/lib/fermix_channels/dispatcher.ex`
  - Accept optional `:reply_fn` in dispatch opts.
  - Use it instead of `channel.build_reply/1` when provided.

- Modify `apps/fermix_channels/lib/fermix_channels/cli.ex`
  - Add `:session_id` support to `parse_input/2`.
  - Add `dispatch_input_sync/2` that uses `parse_input/2` + `Dispatcher.dispatch/2` and waits for one reply.

- Modify `apps/fermix_core/lib/fermix/cli/daemon.ex`
  - Add `agent_message` socket method.
  - Resolve the channel bridge from `Application.get_env(:fermix_core, :cli_channel_bridge, Module.concat(["FermixChannels", "CLI"]))`.

- Modify `apps/fermix_core/lib/fermix/cli/daemon/client.ex`
  - Add `agent_message/2` wrapper.

- Create `apps/fermix_core/lib/fermix/cli/chat_command.ex`
  - Parse `ask` / `chat` argv.
  - Support message args, explicit `--stdin`, `--session`, `--timeout`, and `--json`.
  - Send request to daemon socket and render response.

- Modify `apps/fermix_core/lib/fermix/cli.ex`
  - Wire `ask` and `chat` aliases.

- Tests:
  - Extend `apps/fermix_channels/test/fermix_channels/cli_test.exs`.
  - Extend `apps/fermix_channels/test/fermix_channels/dispatcher_test.exs`.
  - Extend `apps/fermix_core/test/fermix/cli/daemon_test.exs`.
  - Add `apps/fermix_core/test/fermix/cli/chat_command_test.exs`.

- Docs:
  - Update `README.md`.

---

## CLI Contract

```bash
fermix ask "hello"
fermix chat "hello"
echo "hello" | fermix ask --stdin
fermix ask --session scenario-web-fetch "validate web_fetch localhost rejection"
fermix ask --timeout 180000 --json "hello"
```

Behavior:

- `ask` and `chat` are one-shot aliases.
- Default session id is `cli`.
- `--session ID` maps to the local CLI channel `chat_id`, so scenarios can isolate conversation history.
- `--stdin` is required for stdin mode. No-arg invocation fails fast with usage.
- `--timeout MS` controls both daemon socket wait and agent reply wait.
- JSON success envelope: `{"status":"ok","response":"...","session_id":"..."}`.
- JSON error envelope: `{"status":"error","error":"...","session_id":"..."}` when a session is known, otherwise no `session_id`.
- Not-running daemon returns exit code `3`, consistent with current socket-backed commands.

---

## Task 1: Reusable CLI Channel Sync Path

**Files:**
- Modify: `apps/fermix_channels/lib/fermix_channels/dispatcher.ex`
- Modify: `apps/fermix_channels/lib/fermix_channels/cli.ex`
- Test: `apps/fermix_channels/test/fermix_channels/dispatcher_test.exs`
- Test: `apps/fermix_channels/test/fermix_channels/cli_test.exs`

- [ ] **Step 1: Add failing dispatcher override test**

In `apps/fermix_channels/test/fermix_channels/dispatcher_test.exs`, add:

```elixir
test "uses explicit reply_fn override when provided" do
  message =
    Message.new!(%{
      id: "message-override",
      content: "hello",
      sender: "operator",
      channel: "cli",
      chat_id: "cli",
      reply_target: "cli"
    })

  test_pid = self()

  assert :ok =
           Dispatcher.dispatch([message],
             channel: FermixChannels.CLI,
             agent: TestAgent,
             agent_server: test_pid,
             reply_fn: fn text ->
               send(test_pid, {:captured_reply, text})
               :ok
             end
           )

  assert_receive {:handled_message, agent_message}
  assert agent_message.content == "hello"
  assert is_function(agent_message.reply_fn, 1)

  assert :ok = agent_message.reply_fn.("reply")
  assert_receive {:captured_reply, "reply"}
end
```

If the local test agent message tag in the existing file is not `:handled_message`, use the tag already defined by that file's `TestAgent`.

- [ ] **Step 2: Add failing CLI sync tests**

In `apps/fermix_channels/test/fermix_channels/cli_test.exs`, add:

```elixir
defmodule ReplyAgent do
  def handle_message(message, test_pid) do
    send(test_pid, {:sync_agent_message, message})
    message.reply_fn.("reply: #{message.content}")
    :ok
  end
end

defmodule SilentAgent do
  def handle_message(_message, _test_pid), do: :ok
end

test "parse_input accepts a custom session id" do
  assert {:ok, [%Message{} = message]} =
           CLI.parse_input("hello", sender: "operator", session_id: "scenario-1")

  assert message.content == "hello"
  assert message.channel == "cli"
  assert message.chat_id == "scenario-1"
  assert message.reply_target == "scenario-1"
  assert message.metadata == %{source: :cli}
end

test "dispatch_input_sync reuses the CLI channel and captures one reply" do
  assert {:ok, %{response: "reply: hello", session_id: "scenario-1"}} =
           CLI.dispatch_input_sync("hello",
             sender: "operator",
             session_id: "scenario-1",
             timeout_ms: 1_000,
             agent: ReplyAgent,
             agent_server: self()
           )

  assert_receive {:sync_agent_message, message}
  assert message.content == "hello"
  assert message.sender == "operator"
  assert message.channel == "cli"
  assert message.chat_id == "scenario-1"
  assert message.metadata == %{source: :cli}
end

test "dispatch_input_sync returns parser and timeout errors" do
  assert {:error, :empty_input} =
           CLI.dispatch_input_sync("   ",
             agent: ReplyAgent,
             agent_server: self(),
             timeout_ms: 1_000
           )

  assert {:error, :timeout} =
           CLI.dispatch_input_sync("hello",
             agent: SilentAgent,
             agent_server: self(),
             timeout_ms: 10
           )
end
```

- [ ] **Step 3: Run failing channel tests**

Run:

```bash
mix test apps/fermix_channels/test/fermix_channels/dispatcher_test.exs \
  apps/fermix_channels/test/fermix_channels/cli_test.exs
```

Expected: failures for missing reply override / missing `dispatch_input_sync/2`.

- [ ] **Step 4: Implement dispatcher reply override**

In `apps/fermix_channels/lib/fermix_channels/dispatcher.ex`, thread `reply_fn` through dispatch:

```elixir
reply_fn_override = Keyword.get(opts, :reply_fn)
```

Pass it into `dispatch_message/6`, then choose the reply function with:

```elixir
defp build_reply_fn(_channel, _message, reply_fn) when is_function(reply_fn, 1) do
  fn text ->
    case reply_fn.(text) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("Channel reply delivery failed: #{inspect(reason)}")
        error
    end
  end
end

defp build_reply_fn(channel, %Message{} = message, _reply_fn) do
  build_reply_fn(channel, message)
end
```

Keep the existing `build_reply_fn/2` intact for all normal channels.

- [ ] **Step 5: Implement CLI session and sync helper**

In `apps/fermix_channels/lib/fermix_channels/cli.ex`, update `parse_input/2`:

```elixir
session_id = opts |> Keyword.get(:session_id, @channel) |> to_string()

message =
  Message.new!(%{
    id: message_id(),
    content: content,
    sender: sender,
    channel: @channel,
    chat_id: session_id,
    reply_target: session_id,
    metadata: %{source: :cli}
  })
```

Add:

```elixir
@default_timeout_ms 120_000

@spec dispatch_input_sync(String.t(), keyword()) ::
        {:ok, %{response: String.t(), session_id: String.t()}} | {:error, term()}
def dispatch_input_sync(input, opts \\ []) when is_binary(input) do
  timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
  parent = self()
  ref = make_ref()

  with {:ok, [message]} <- parse_input(input, opts),
       :ok <-
         Dispatcher.dispatch([message],
           channel: __MODULE__,
           agent: Keyword.get(opts, :agent, MainAgent),
           agent_server: Keyword.get(opts, :agent_server, MainAgent),
           reply_fn: fn text ->
             send(parent, {ref, {:reply, text}})
             :ok
           end
         ) do
    await_reply(ref, message.chat_id, timeout_ms)
  end
end

defp await_reply(ref, session_id, timeout_ms) do
  receive do
    {^ref, {:reply, response}} when is_binary(response) ->
      {:ok, %{response: response, session_id: session_id}}

    {^ref, {:reply, response}} ->
      {:ok, %{response: inspect(response), session_id: session_id}}
  after
    timeout_ms ->
      {:error, :timeout}
  end
end
```

Do not put pid/ref values in `Message.metadata`; `MainAgent` stores message metadata in conversation history.

- [ ] **Step 6: Verify channel tests pass**

Run:

```bash
mix test apps/fermix_channels/test/fermix_channels/dispatcher_test.exs \
  apps/fermix_channels/test/fermix_channels/cli_test.exs
```

Expected: channel tests pass.

---

## Task 2: Daemon Socket Method

**Files:**
- Modify: `apps/fermix_core/lib/fermix/cli/daemon.ex`
- Modify: `apps/fermix_core/lib/fermix/cli/daemon/client.ex`
- Test: `apps/fermix_core/test/fermix/cli/daemon_test.exs`

- [ ] **Step 1: Add failing daemon tests**

In `apps/fermix_core/test/fermix/cli/daemon_test.exs`, add a local bridge module:

```elixir
defmodule TestCLIBridge do
  def dispatch_input_sync(content, opts) do
    test_pid = Application.fetch_env!(:fermix_core, :daemon_test_pid)
    send(test_pid, {:bridge_call, content, opts})

    {:ok,
     %{
       response: "daemon reply: #{content}",
       session_id: Keyword.get(opts, :session_id, "cli")
     }}
  end
end
```

In setup, set and restore env:

```elixir
previous_bridge = Application.get_env(:fermix_core, :cli_channel_bridge)
previous_pid = Application.get_env(:fermix_core, :daemon_test_pid)

Application.put_env(:fermix_core, :cli_channel_bridge, TestCLIBridge)
Application.put_env(:fermix_core, :daemon_test_pid, self())

on_exit(fn ->
  restore_app_env(:cli_channel_bridge, previous_bridge)
  restore_app_env(:daemon_test_pid, previous_pid)
end)
```

Add tests:

```elixir
test "agent_message routes the prompt through the configured CLI bridge", %{socket_path: socket_path} do
  assert {:ok, reply} =
           Client.agent_message(
             %{"content" => "hello", "session_id" => "daemon-test", "timeout_ms" => 1_000},
             socket_path: socket_path,
             timeout: 2_000
           )

  assert reply["status"] == "ok"
  assert reply["response"] == "daemon reply: hello"
  assert reply["session_id"] == "daemon-test"

  assert_receive {:bridge_call, "hello", opts}
  assert Keyword.get(opts, :session_id) == "daemon-test"
  assert Keyword.get(opts, :timeout_ms) == 1_000
end

test "agent_message returns empty input errors without calling the bridge", %{socket_path: socket_path} do
  assert {:ok, reply} =
           Client.agent_message(%{"content" => "   "},
             socket_path: socket_path,
             timeout: 1_000
           )

  assert reply["status"] == "error"
  assert reply["error"] == "empty_input"
  refute_received {:bridge_call, _, _}
end
```

Add helper:

```elixir
defp restore_app_env(key, nil), do: Application.delete_env(:fermix_core, key)
defp restore_app_env(key, value), do: Application.put_env(:fermix_core, key, value)
```

- [ ] **Step 2: Run failing daemon tests**

Run:

```bash
mix test apps/fermix_core/test/fermix/cli/daemon_test.exs
```

Expected: failure for missing `Client.agent_message/2` / unknown daemon method.

- [ ] **Step 3: Add client helper**

In `apps/fermix_core/lib/fermix/cli/daemon/client.ex`, add:

```elixir
@spec agent_message(map(), keyword()) :: {:ok, map()} | {:error, term()}
def agent_message(params, opts \\ []) when is_map(params) do
  opts = Keyword.put(opts, :params, params)
  request("agent_message", opts)
end
```

- [ ] **Step 4: Add daemon method**

In `apps/fermix_core/lib/fermix/cli/daemon.ex`, add request handling:

```elixir
{:ok, %{"method" => "agent_message"} = request} ->
  agent_message_reply(request)
```

Add helpers:

```elixir
defp agent_message_reply(request) do
  params = Map.get(request, "params", %{})
  content = params |> Map.get("content", "") |> to_string() |> String.trim()
  session_id = params |> Map.get("session_id", "cli") |> to_string()
  timeout_ms = Map.get(params, "timeout_ms", 120_000)

  if content == "" do
    %{status: "error", error: "empty_input", session_id: session_id}
  else
    cli_bridge_reply(content, session_id: session_id, timeout_ms: timeout_ms)
  end
end

defp cli_bridge_reply(content, opts) do
  bridge = Application.get_env(:fermix_core, :cli_channel_bridge, default_cli_channel_bridge())

  case apply(bridge, :dispatch_input_sync, [content, opts]) do
    {:ok, %{response: response, session_id: session_id}} ->
      %{status: "ok", response: response, session_id: session_id}

    {:error, reason} ->
      %{status: "error", error: reason_to_string(reason), session_id: Keyword.get(opts, :session_id)}
  end
rescue
  UndefinedFunctionError ->
    %{status: "error", error: "cli_channel_unavailable", session_id: Keyword.get(opts, :session_id)}
end

defp default_cli_channel_bridge do
  Module.concat(["FermixChannels", "CLI"])
end

defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
defp reason_to_string(reason) when is_binary(reason), do: reason
defp reason_to_string(reason), do: inspect(reason)
```

- [ ] **Step 5: Verify daemon tests pass**

Run:

```bash
mix test apps/fermix_core/test/fermix/cli/daemon_test.exs
```

Expected: daemon tests pass.

---

## Task 3: Top-Level Chat Command

**Files:**
- Create: `apps/fermix_core/lib/fermix/cli/chat_command.ex`
- Modify: `apps/fermix_core/lib/fermix/cli.ex`
- Test: `apps/fermix_core/test/fermix/cli/chat_command_test.exs`

- [ ] **Step 1: Add failing command tests**

Create `apps/fermix_core/test/fermix/cli/chat_command_test.exs`:

```elixir
defmodule Fermix.CLI.ChatCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.ChatCommand
  alias Fermix.CLI.Daemon

  defmodule TestCLIBridge do
    def dispatch_input_sync(content, opts) do
      test_pid = Application.fetch_env!(:fermix_core, :chat_command_test_pid)
      send(test_pid, {:chat_command_bridge_call, content, opts})

      {:ok,
       %{
         response: "chat reply: #{content}",
         session_id: Keyword.get(opts, :session_id, "cli")
       }}
    end
  end

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_bridge = Application.get_env(:fermix_core, :cli_channel_bridge)
    previous_pid = Application.get_env(:fermix_core, :chat_command_test_pid)

    socket_dir = mkdir!()
    task_sup = :"chat_command_task_sup_#{System.unique_integer([:positive, :monotonic])}"
    System.put_env("FERMIX_HOME", socket_dir)
    Application.put_env(:fermix_core, :cli_channel_bridge, TestCLIBridge)
    Application.put_env(:fermix_core, :chat_command_test_pid, self())

    {:ok, _sup} = Task.Supervisor.start_link(name: task_sup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"chat_command_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: Path.join(socket_dir, "daemon.sock"),
        task_supervisor: task_sup
      )

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, 1_000)
      restore_env("FERMIX_HOME", previous_home)
      restore_app_env(:cli_channel_bridge, previous_bridge)
      restore_app_env(:chat_command_test_pid, previous_pid)
      File.rm_rf!(socket_dir)
    end)

    :ok
  end

  test "prints daemon agent reply for argv content" do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:chat_exit, ChatCommand.run(["hello", "world"])})
      end)

    assert_receive {:chat_exit, 0}
    assert output == "chat reply: hello world\n"
    assert_receive {:chat_command_bridge_call, "hello world", opts}
    assert Keyword.get(opts, :session_id) == "cli"
  end

  test "passes session and timeout options" do
    test_self = self()

    output =
      capture_io(fn ->
        send(
          test_self,
          {:chat_exit, ChatCommand.run(["--session", "scenario-1", "--timeout", "1000", "hello"])}
        )
      end)

    assert_receive {:chat_exit, 0}
    assert output == "chat reply: hello\n"
    assert_receive {:chat_command_bridge_call, "hello", opts}
    assert Keyword.get(opts, :session_id) == "scenario-1"
    assert Keyword.get(opts, :timeout_ms) == 1_000
  end

  test "prints JSON success envelope" do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:chat_exit, ChatCommand.run(["--json", "hello"])})
      end)

    assert_receive {:chat_exit, 0}
    decoded = Jason.decode!(output)
    assert decoded["status"] == "ok"
    assert decoded["response"] == "chat reply: hello"
    assert decoded["session_id"] == "cli"
  end

  test "reads stdin only when --stdin is provided" do
    test_self = self()

    output =
      capture_io("from stdin\n", fn ->
        send(test_self, {:chat_exit, ChatCommand.run(["--stdin"])})
      end)

    assert_receive {:chat_exit, 0}
    assert output == "chat reply: from stdin\n"
  end

  test "returns usage error for missing message" do
    output =
      capture_io(:stderr, fn ->
        assert ChatCommand.run([]) == 2
      end)

    assert output =~ "usage: fermix ask"
  end

  test "returns not-running error when daemon is unavailable" do
    previous_home = System.get_env("FERMIX_HOME")
    missing_home = mkdir!()
    System.put_env("FERMIX_HOME", missing_home)

    output =
      capture_io(:stderr, fn ->
        assert ChatCommand.run(["hello"]) == 3
      end)

    assert output =~ "fermix: not running"

    restore_env("FERMIX_HOME", previous_home)
    File.rm_rf!(missing_home)
  end

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-chat-command-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_app_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
```

- [ ] **Step 2: Implement command**

Create `apps/fermix_core/lib/fermix/cli/chat_command.ex`:

```elixir
defmodule Fermix.CLI.ChatCommand do
  @moduledoc """
  `fermix ask` / `fermix chat` one-shot local prompt command.
  """

  alias Fermix.CLI.Daemon.Client

  @default_timeout_ms 120_000

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    with {:ok, opts, words} <- parse(argv),
         {:ok, content} <- content_from(words, opts),
         {:ok, reply} <- request_agent(content, opts) do
      render_reply(reply, opts)
    else
      {:error, :usage} -> usage()
      {:error, :not_running} -> not_running()
      {:error, reason} -> render_error(reason, [])
    end
  end

  defp parse(argv) do
    {opts, words, invalid} =
      OptionParser.parse(argv,
        strict: [session: :string, timeout: :integer, json: :boolean, stdin: :boolean],
        aliases: [s: :session, t: :timeout]
      )

    case invalid do
      [] -> {:ok, opts, words}
      _ -> {:error, :usage}
    end
  end

  defp content_from(words, opts) do
    content =
      cond do
        words != [] -> Enum.join(words, " ")
        Keyword.get(opts, :stdin, false) -> read_stdin()
        true -> ""
      end
      |> to_string()
      |> String.trim()

    if content == "", do: {:error, :usage}, else: {:ok, content}
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      {:error, _reason} -> ""
      data -> data
    end
  end

  defp request_agent(content, opts) do
    timeout_ms = Keyword.get(opts, :timeout, @default_timeout_ms)

    params =
      %{"content" => content, "timeout_ms" => timeout_ms}
      |> maybe_put("session_id", Keyword.get(opts, :session))

    Client.agent_message(params, timeout: timeout_ms + 1_000)
  end

  defp render_reply(%{"status" => "ok"} = reply, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(reply))
    else
      IO.puts(reply["response"])
    end

    0
  end

  defp render_reply(%{"status" => "error"} = reply, opts) do
    render_error(Map.get(reply, "error", "unknown_error"), opts, reply)
  end

  defp render_error(reason, opts, extra \\ %{}) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(Map.merge(%{"status" => "error", "error" => to_string(reason)}, extra)))
    else
      IO.puts(:stderr, "fermix: #{reason}")
    end

    1
  end

  defp not_running do
    IO.puts(:stderr, "fermix: not running")
    3
  end

  defp usage do
    IO.puts(:stderr, """
    usage: fermix ask [--session ID] [--timeout MS] [--json] MESSAGE...
           fermix ask --stdin [--session ID] [--timeout MS] [--json]
           fermix chat [--session ID] [--timeout MS] [--json] MESSAGE...
           fermix chat --stdin [--session ID] [--timeout MS] [--json]
    """)

    2
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
```

- [ ] **Step 3: Wire top-level CLI**

Modify `apps/fermix_core/lib/fermix/cli.ex`:

```elixir
alias Fermix.CLI.ChatCommand
```

```elixir
defp dispatch("ask", rest), do: ChatCommand.run(rest)
defp dispatch("chat", rest), do: ChatCommand.run(rest)
```

Add usage lines:

```elixir
fermix ask    [--stdin] [--session ID] [--timeout MS] [--json] MESSAGE...
fermix chat   [--stdin] [--session ID] [--timeout MS] [--json] MESSAGE...
```

- [ ] **Step 4: Verify command tests pass**

Run:

```bash
mix test apps/fermix_core/test/fermix/cli/chat_command_test.exs
```

Expected: command tests pass.

---

## Task 4: Docs and Validation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Add CLI reference:

```markdown
| `ask` / `chat` | Send one local prompt to the running daemon and print the MainAgent reply |
```

Add local examples:

````markdown
Local one-shot agent checks:

```bash
fermix ask "say pong"
fermix ask --session scenario-web-fetch "validate web_fetch localhost rejection"
echo "summarize current health" | fermix ask --stdin --json
```
````

Add dev-server caveat:

```markdown
`mix phx.server` boots the dev supervision tree but does not enable the release
daemon control socket. Use the running IEx shell for direct local agent calls,
or run the release command path with `fermix run` when testing `fermix ask`,
`fermix status`, `fermix health`, and other socket-backed CLI commands.
```

- [ ] **Step 2: Format**

Run:

```bash
mix format
```

Expected: exit `0`.

- [ ] **Step 3: Compile**

Run:

```bash
mix compile
```

Expected: exit `0`.

- [ ] **Step 4: Run focused tests**

Run:

```bash
mix test apps/fermix_channels/test/fermix_channels/dispatcher_test.exs \
  apps/fermix_channels/test/fermix_channels/cli_test.exs \
  apps/fermix_core/test/fermix/cli/daemon_test.exs \
  apps/fermix_core/test/fermix/cli/chat_command_test.exs
```

Expected: all focused tests pass.

- [ ] **Step 5: Run broader CLI/channel tests**

Run:

```bash
mix test apps/fermix_core/test/fermix/cli apps/fermix_channels/test/fermix_channels
```

Expected: pass unless the local sandbox blocks socket startup. If blocked by `:eperm`, report the exact failure and do not overclaim.

---

## Review Notes

- The first version of this plan duplicated local channel behavior in `fermix_core`; this revision removes that duplicate bridge.
- The daemon still lives in `fermix_core`, but it calls the channel bridge by runtime module to avoid a circular umbrella dependency.
- Test injection is via `Application` env for the bridge module, not daemon state fields.
- No pid/ref is stored in `Message.metadata`.
- JSON success and error output now use explicit `status` envelopes.
