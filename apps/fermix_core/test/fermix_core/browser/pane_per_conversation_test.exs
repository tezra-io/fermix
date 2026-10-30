defmodule FermixCore.Browser.PanePerConversationTest do
  # A pane task is bound to the turn that started it and ends with it
  # (`HostServer`), so the Fermix app's pane is each conversation's own while
  # the owner's Chrome is one profile for all of them. Driven end to end through
  # the tool's entry point and the browser tree's own processes, with a fake app
  # connection; no Chrome is launched.
  #
  # Sync: drives the tree's own availability process, profile registry and turn
  # marker, so no other module may route while this one holds a host.
  use ExUnit.Case, async: false

  alias FermixCore.Browser
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Browser.Scope
  alias FermixTestSupport.FakeBrowserHostConnection

  @registry FermixCore.Browser.Registry

  # The owner's live Chrome, as the registry records one, answering with its own
  # pid so a test can tell whether two conversations reached the same profile.
  defmodule ChromeStub do
    use GenServer

    def start_link(key) do
      now = System.monotonic_time(:millisecond)

      GenServer.start_link(__MODULE__, nil,
        name: {:via, Registry, {FermixCore.Browser.Registry, key, {now, :cdp}}}
      )
    end

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call({:request, _request}, _from, state),
      do: {:reply, {:ok, %{"ok" => true, "served_by" => inspect(self())}}, state}
  end

  setup do
    {:ok, connection} =
      FakeBrowserHostConnection.start_link(%{"tab.list" => {:ok, %{"tabs" => []}}})

    endpoint = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      Process.exit(connection, :kill)
      Process.exit(endpoint, :kill)
    end)

    :ok = HostAvailability.listening(HostAvailability, endpoint)
    :ok = HostAvailability.attached(HostAvailability, connection, 1)
    :ok = HostAvailability.report(HostAvailability, true, nil)
    %{connection: connection}
  end

  defp conversation(label) do
    key = {"telegram", "#{label}-#{System.unique_integer([:positive])}", :root}
    on_exit(fn -> ProfileManager.stop_owner(Scope.pane_key("owner", key)) end)
    key
  end

  # A turn: the process that makes a conversation's browser calls, and the one
  # its pane task is bound to.
  defp turn! do
    {:ok, pid} = Agent.start(fn -> nil end)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    pid
  end

  defp tabs(turn, conversation) do
    context = %{agent_name: "t", conversation_key: conversation, source_trust: :operator}
    Agent.get(turn, fn _ -> Browser.execute(%{"action" => "tabs"}, context) end, 10_000)
  end

  # The pane task the app was last asked something on.
  defp last_task(connection) do
    {"tab.list", %{"task_id" => task}} =
      connection |> FakeBrowserHostConnection.requests() |> List.last()

    task
  end

  defp pane_server!(conversation) do
    [{pid, _value}] =
      Registry.lookup(@registry, {Scope.pane_key("owner", conversation), "fermix"})

    pid
  end

  defp on_pane!(turn, conversation, connection) do
    assert {{:ok, _json}, :fermix_app} = tabs(turn, conversation)
    last_task(connection)
  end

  defp end_turn!(turn, conversation) do
    pane = pane_server!(conversation)
    ref = Process.monitor(pane)
    Agent.stop(turn)
    assert_receive {:DOWN, ^ref, :process, ^pane, _reason}
  end

  test "one conversation's turn ending does not end another's pane task", %{connection: conn} do
    {chat_a, chat_b} = {conversation("a"), conversation("b")}
    {turn_a, turn_b} = {turn!(), turn!()}

    task_a = on_pane!(turn_a, chat_a, conn)
    task_b = on_pane!(turn_b, chat_b, conn)
    assert task_a != task_b

    end_turn!(turn_a, chat_a)

    assert on_pane!(turn_b, chat_b, conn) == task_b
    assert FakeBrowserHostConnection.releases(conn) == [task_a]
  end

  test "a pane task the person cancels marks only its own conversation's turn", %{
    connection: conn
  } do
    {chat_a, chat_b} = {conversation("a"), conversation("b")}
    {turn_a, turn_b} = {turn!(), turn!()}
    _task_a = on_pane!(turn_a, chat_a, conn)
    task_b = on_pane!(turn_b, chat_b, conn)

    pane_a = pane_server!(chat_a)
    ref = Process.monitor(pane_a)
    send(pane_a, {:browser_host_cancelled, conn, "cancelled from its tab"})
    assert_receive {:DOWN, ^ref, :process, ^pane_a, _reason}

    assert {{:error, %Error{code: "cancelled"}}, :fermix_app} = tabs(turn_a, chat_a)
    assert on_pane!(turn_b, chat_b, conn) == task_b
  end

  test "a conversation whose pane profile is gone is decided afresh, and only it",
       %{connection: conn} do
    {chat_a, chat_b} = {conversation("a"), conversation("b")}
    {first_turn_a, turn_b} = {turn!(), turn!()}
    first_task_a = on_pane!(first_turn_a, chat_a, conn)
    task_b = on_pane!(turn_b, chat_b, conn)

    end_turn!(first_turn_a, chat_a)

    next_task_a = on_pane!(turn!(), chat_a, conn)
    refute next_task_a in [first_task_a, task_b]
    assert on_pane!(turn_b, chat_b, conn) == task_b
  end

  test "the owner's live Chrome is one profile for every conversation without a pane" do
    owner_chrome = start_supervised!({ChromeStub, {"owner", "fermix"}})
    {chat_a, chat_b} = {conversation("a"), conversation("b")}

    served =
      for chat <- [chat_a, chat_b] do
        assert {{:ok, json}, :cdp} = tabs(turn!(), chat)
        Jason.decode!(json)["served_by"]
      end

    assert served == [inspect(owner_chrome), inspect(owner_chrome)]

    for chat <- [chat_a, chat_b] do
      assert ProfileManager.backend(Scope.pane_key("owner", chat), "fermix") == nil
    end
  end
end
