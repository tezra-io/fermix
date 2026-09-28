defmodule FermixCore.Realtime.SessionServerAccessTest do
  @moduledoc """
  An access-sensitive command on a Realtime call (`Capabilities.AccessGate`):
  the call's taint lasts the call, and a parked command runs only on the owner's
  spoken yes, bound to the first input item committed after the park.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionServer

  # The test registers under this name to be told about each provider event as it
  # is sent, so a confirmed run's status item is awaited rather than polled for.
  @observer :access_test_observer

  defmodule FakeOpenAIClient do
    def start_link(opts), do: Agent.start_link(fn -> %{opts: opts, events: []} end)

    def send_event(pid, event) do
      if observer = Process.whereis(:access_test_observer),
        do: send(observer, {:openai_event, event})

      Agent.update(pid, fn state -> %{state | events: state.events ++ [event]} end)
    end

    def close(_pid), do: :ok
    def events(pid), do: Agent.get(pid, & &1.events)
  end

  def unlock(args, _context, test_pid) do
    send(test_pid, {:unlocked, args})
    {:ok, %{success: true, output: ~s({"result":true}), error: nil}}
  end

  def read_page(_args, _context), do: {:ok, %{success: true, output: "page text", error: nil}}

  def speak(_args, _context, test_pid) do
    send(test_pid, :spoke)
    {:ok, %{success: true, output: "said it", error: nil}}
  end

  def crash(_args, _context), do: raise("the helper connection dropped mid-command")

  # A car command the test holds open, so its outcome lands when the test says.
  def honk(_args, _context, test_pid) do
    send(test_pid, {:honking, self()})

    receive do
      :release -> {:ok, %{success: true, output: ~s({"result":true}), error: nil}}
    after
      30_000 -> raise "the test never released the honk"
    end
  end

  setup do
    registry = :"rt_access_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    unlock = unlock_capability(self())
    trunk = trunk_capability()
    honk = honk_capability(self())
    web = web_capability()
    shell = shell_capability(self())
    :ok = CapabilityRegistry.register(registry, unlock)
    :ok = CapabilityRegistry.register(registry, trunk)
    :ok = CapabilityRegistry.register(registry, honk)
    Process.register(self(), @observer)
    task_supervisor = start_supervised!({Task.Supervisor, []})
    scope = "session:access-#{System.unique_integer([:positive])}"

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        session_scope: scope,
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [unlock, trunk, honk, web, shell],
        capability_registry: registry,
        task_supervisor: task_supervisor,
        reconnect_backoff_ms: [10, 10, 10],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    :ok = SessionServer.call_start(server)
    # OpenAI confirms the call's socket: the call is live.
    :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    %{server: server, openai: SessionServer.openai_pid(server), call_id: scope}
  end

  defp unlock_capability(test_pid) do
    Capability.new(%{
      name: "tesla_unlock_doors",
      description: "Unlock the car's doors.",
      parameters: %{"type" => "object"},
      kind: :mcp,
      executor: {__MODULE__, :unlock, [test_pid]},
      policy_class: :external_api,
      metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "tesla"}
    })
  end

  # A flagged command whose helper crashes once it is finally run.
  defp trunk_capability do
    Capability.new(%{
      name: "tesla_actuate_trunk",
      description: "Open the trunk.",
      parameters: %{"type" => "object"},
      kind: :mcp,
      executor: {__MODULE__, :crash, []},
      policy_class: :external_api,
      metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "tesla"}
    })
  end

  defp honk_capability(test_pid) do
    Capability.new(%{
      name: "tesla_honk_horn",
      description: "Honk the horn.",
      parameters: %{"type" => "object"},
      kind: :mcp,
      executor: {__MODULE__, :honk, [test_pid]},
      policy_class: :external_api,
      metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "tesla"}
    })
  end

  defp web_capability do
    Capability.new(%{
      name: "web_fetch",
      description: "Fetch a page.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :read_page, []},
      policy_class: :network
    })
  end

  # Stands in for `shell`: a command whose audio (`say yes`) the owner's mic
  # would pick up.
  defp shell_capability(test_pid) do
    Capability.new(%{
      name: "shell",
      description: "Run a command.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :speak, [test_pid]},
      policy_class: :exec
    })
  end

  defp call_tool(server, call_id, name) do
    :ok =
      SessionServer.handle_provider_event(
        server,
        {:function_call,
         %{"call_id" => call_id, "name" => name, "arguments" => ~s({"vin":"5YJ"})}}
      )

    assert_receive {:realtime, %{type: "tool_event", status: status, name: ^name}}
                   when status in ["completed", "error"]

    :ok
  end

  defp commit(server, item_id),
    do:
      SessionServer.handle_provider_event(
        server,
        {:input_audio_committed, %{"item_id" => item_id}}
      )

  defp transcript(server, item_id, text),
    do: SessionServer.handle_provider_event(server, {:user_transcript_done, item_id, text})

  defp status_texts(openai) do
    openai
    |> FakeOpenAIClient.events()
    |> Enum.flat_map(fn
      %{type: "conversation.item.create", item: %{type: "message", content: [%{text: text}]}} ->
        [text]

      _other ->
        []
    end)
  end

  # Drop the provider events already sent, so the next awaited one is new.
  defp flush_openai_events do
    receive do
      {:openai_event, _event} -> flush_openai_events()
    after
      0 -> :ok
    end
  end

  # The owner says yes to the honk a tool call parked after outside content.
  # Returns its intent id and the confirmed run, still held open by the test.
  defp start_confirmed_honk(server, call_id) do
    call_tool(server, "c1", "web_fetch")
    call_tool(server, "c2", "tesla_honk_horn")
    assert {:ok, intent} = Pending.voice_pending(call_id)
    assert :ok = commit(server, "item-yes")
    assert :ok = transcript(server, "item-yes", "yes")
    assert_receive {:honking, run}, 2_000
    {intent, run}
  end

  # Kill a process and return once it is gone: its exit signals, including
  # the session's EXIT through the link, have been sent.
  defp kill_and_await(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
  end

  # Let the confirmed run finish and return once its reply is in the
  # session's mailbox (the reply is sent before the task exits).
  defp release_and_await(run) do
    ref = Process.monitor(run)
    send(run, :release)
    assert_receive {:DOWN, ^ref, :process, ^run, _reason}, 2_000
  end

  # The reconnect's socket, once the session has sent it its session.update.
  defp await_reconnected(server, old) do
    assert_receive {:openai_event, %{type: "session.update"}}, 2_000
    socket = SessionServer.openai_pid(server)
    assert is_pid(socket) and socket != old
    socket
  end

  # The status items that carry a confirmed run's outcome, sent to one socket.
  defp said_yes(openai), do: Enum.filter(status_texts(openai), &(&1 =~ "The owner said yes"))

  defp response_creates(openai),
    do: openai |> FakeOpenAIClient.events() |> Enum.count(&(&1.type == "response.create"))

  defp tool_output(openai, call_id) do
    Enum.find_value(FakeOpenAIClient.events(openai), fn
      %{type: "conversation.item.create", item: %{call_id: ^call_id, output: output}} -> output
      _other -> nil
    end)
  end

  test "a clean call runs the command at once", %{server: server} do
    call_tool(server, "c1", "tesla_unlock_doors")
    assert_received {:unlocked, %{"vin" => "5YJ"}}
  end

  test "after outside content, a parked command runs once on the next committed yes", %{
    server: server,
    openai: openai,
    call_id: call_id
  } do
    call_tool(server, "c1", "web_fetch")
    call_tool(server, "c2", "tesla_unlock_doors")
    refute_received {:unlocked, _}
    assert tool_output(openai, "c2") =~ "say yes"
    assert {:ok, _intent} = Pending.voice_pending(call_id)

    assert :ok = commit(server, "item-yes")
    before = response_creates(openai)
    flush_openai_events()
    assert :ok = transcript(server, "item-yes", "Yes.")

    assert_receive {:unlocked, %{"vin" => "5YJ"}}, 2_000
    assert_receive {:openai_event, %{type: "response.create"}}, 2_000
    assert [said_yes] = Enum.filter(status_texts(openai), &(&1 =~ "The owner said yes"))
    # The helper's own words reach the model framed as data.
    assert said_yes =~ "<untrusted_tool_result"
    assert said_yes =~ "tesla_unlock_doors ran"
    assert response_creates(openai) == before + 1
    refute_received {:unlocked, _}
  end

  test "a re-call while pending gets the waiting text, and after the yes the done text", %{
    server: server,
    openai: openai
  } do
    call_tool(server, "c1", "web_fetch")
    call_tool(server, "c2", "tesla_unlock_doors")
    call_tool(server, "c3", "tesla_unlock_doors")
    assert tool_output(openai, "c3") =~ "already waiting"

    assert :ok = commit(server, "item-yes")
    flush_openai_events()
    assert :ok = transcript(server, "item-yes", "yes")
    assert_receive {:unlocked, _args}, 2_000
    assert_receive {:openai_event, %{type: "response.create"}}, 2_000

    call_tool(server, "c4", "tesla_unlock_doors")
    assert tool_output(openai, "c4") =~ "Already done"
    refute_received {:unlocked, _}
  end

  test "anything but a yes discards the command with a status item and no response", %{
    server: server,
    openai: openai,
    call_id: call_id
  } do
    call_tool(server, "c1", "web_fetch")
    call_tool(server, "c2", "tesla_unlock_doors")

    assert :ok = commit(server, "item-no")
    before = response_creates(openai)
    assert :ok = transcript(server, "item-no", "No, leave it locked.")
    _ = :sys.get_state(server)

    refute_received {:unlocked, _}
    assert Enum.any?(status_texts(openai), &(&1 =~ "did not say yes"))
    assert response_creates(openai) == before
    assert :none = Pending.voice_pending(call_id)
  end

  # A model that read outside content must not supply the owner's yes itself
  # (a shell `say yes` the mic picks up), so while the parked command waits for
  # the answer nothing else in the call runs.
  test "while a command waits on the owner's answer, no other tool runs", %{
    server: server,
    openai: openai
  } do
    call_tool(server, "c1", "web_fetch")
    call_tool(server, "c2", "tesla_unlock_doors")
    call_tool(server, "c3", "shell")
    refute_received :spoke
    assert tool_output(openai, "c3") =~ "already waiting"

    assert :ok = commit(server, "item-no")
    assert :ok = transcript(server, "item-no", "No.")
    _ = :sys.get_state(server)

    call_tool(server, "c4", "shell")
    assert_received :spoke
  end

  test "an item committed before the park never answers it", %{server: server} do
    assert :ok = commit(server, "item-early")
    call_tool(server, "c1", "web_fetch")
    call_tool(server, "c2", "tesla_unlock_doors")

    assert :ok = transcript(server, "item-early", "yes")
    _ = :sys.get_state(server)
    refute_received {:unlocked, _}

    assert :ok = commit(server, "item-answer")
    assert :ok = transcript(server, "item-answer", "yes")
    assert_receive {:unlocked, _args}, 2_000
  end

  test "an assistant transcript never answers", %{server: server} do
    call_tool(server, "c1", "web_fetch")
    call_tool(server, "c2", "tesla_unlock_doors")
    assert :ok = commit(server, "item-1")

    assert :ok = SessionServer.handle_provider_event(server, {:assistant_transcript_done, "yes"})
    _ = :sys.get_state(server)
    refute_received {:unlocked, _}
  end

  test "outside content read earlier in the call still counts later", %{server: server} do
    call_tool(server, "c1", "web_fetch")
    assert :ok = SessionServer.handle_provider_event(server, {:response_done, %{}})
    call_tool(server, "c2", "tesla_unlock_doors")
    refute_received {:unlocked, _}
  end

  test "a confirmed command that crashes tells the model its outcome is unknown", %{
    server: server,
    openai: openai
  } do
    call_tool(server, "c1", "web_fetch")
    call_tool(server, "c2", "tesla_actuate_trunk")
    assert :ok = commit(server, "item-yes")
    flush_openai_events()

    assert :ok = transcript(server, "item-yes", "yes")

    assert_receive {:openai_event, %{type: "response.create"}}, 2_000
    assert Enum.any?(status_texts(openai), &(&1 =~ "is unknown"))
    refute Enum.any?(status_texts(openai), &(&1 =~ "The owner said yes. "))
  end

  # RT-4 (tla/specs/realtime_session check 27). A reconnect leaves the confirmed
  # run going, so its outcome can land with no live socket; it used to be
  # dropped with a debug log, and the owner never heard whether it ran.
  test "an outcome that lands while the call reconnects is spoken once OpenAI confirms the next socket",
       %{server: server, openai: openai, call_id: call_id} do
    {_intent, run} = start_confirmed_honk(server, call_id)

    # Staged in this order: the socket's EXIT, then the run's reply.
    :sys.suspend(server)
    kill_and_await(openai)
    release_and_await(run)
    flush_openai_events()
    :sys.resume(server)

    assert_receive {:realtime, %{type: "state", state: "reconnecting"}}, 2_000
    next = await_reconnected(server, openai)
    _ = :sys.get_state(server)
    assert said_yes(next) == []
    assert response_creates(next) == 0

    assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert [said] = said_yes(next)
    assert said =~ "tesla_honk_horn ran"
    assert response_creates(next) == 1

    # Once only: a later reconnect OpenAI confirms says nothing more.
    flush_openai_events()
    kill_and_await(next)
    last = await_reconnected(server, next)
    assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert said_yes(last) == []
    assert response_creates(last) == 0
  end

  # The socket died but its EXIT is still queued behind the run's reply: the
  # session still believes it is live, and the status item's send fails.
  test "an outcome whose status item cannot reach the dying socket is spoken after the reconnect",
       %{server: server, openai: openai, call_id: call_id} do
    {_intent, run} = start_confirmed_honk(server, call_id)

    # Staged in this order: the run's reply, then the socket's EXIT.
    :sys.suspend(server)
    release_and_await(run)
    kill_and_await(openai)
    flush_openai_events()
    :sys.resume(server)

    next = await_reconnected(server, openai)
    _ = :sys.get_state(server)
    assert said_yes(next) == []

    assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert [_said] = said_yes(next)
    assert response_creates(next) == 1
  end

  test "an outcome that lands while the call is live is spoken at once, and never again",
       %{server: server, openai: openai, call_id: call_id} do
    {_intent, run} = start_confirmed_honk(server, call_id)
    before = response_creates(openai)
    flush_openai_events()

    send(run, :release)
    assert_receive {:openai_event, %{type: "response.create"}}, 2_000
    assert [_said] = said_yes(openai)
    assert response_creates(openai) == before + 1

    flush_openai_events()
    kill_and_await(openai)
    next = await_reconnected(server, openai)
    assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert said_yes(next) == []
    assert response_creates(next) == 0
  end

  test "a call that ends before it is live again logs the unspoken outcome and sends nothing",
       %{server: server, openai: openai, call_id: call_id} do
    {intent, run} = start_confirmed_honk(server, call_id)
    Process.unlink(server)
    ref = Process.monitor(server)

    :sys.suspend(server)
    kill_and_await(openai)
    release_and_await(run)
    flush_openai_events()
    :sys.resume(server)
    assert_receive {:realtime, %{type: "state", state: "reconnecting"}}, 2_000

    log =
      capture_log(fn ->
        assert :ok = SessionServer.call_stop(server)
        assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :call_stop}}, 2_000
      end)

    assert log =~ "intent #{intent}"
    assert log =~ "tesla_honk_horn"
    refute log =~ "5YJ"
    refute_received {:openai_event, %{type: "response.create"}}
    refute_received {:openai_event, %{type: "conversation.item.create"}}
  end
end
