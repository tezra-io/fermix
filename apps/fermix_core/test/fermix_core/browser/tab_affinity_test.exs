defmodule FermixCore.Browser.TabAffinityTest do
  # The owner's profile is one Chrome shared by every owner conversation, so the
  # tab a call without `target` acts on must be the caller's own, never the tab
  # another conversation opened last. Drives the real CDP backend through a
  # stateful fake target table: no Chrome is launched.
  #
  # async: false — registers a global collector for dispatched CDP calls.
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.ProfileServer

  defmodule Launcher do
    def attach(_config, _profile, _owner, _name), do: :none

    def start(_config, _profile, _owner, _name) do
      {:ok,
       %{
         ws_url: "ws://fake/devtools/browser/x",
         os_pid: 1,
         port_ref: nil,
         headless: true,
         port: 1
       }}
    end

    def stop(_runtime, _config), do: :ok
  end

  # Chrome's target table: `Target.createTarget` adds a page, `closeTarget`
  # removes it, `getTargets` lists what is open. Every command is mirrored to the
  # collector with the session it was sent on, which names the tab it reached.
  defmodule Connection do
    use Agent

    def start_link(_url, _opts), do: Agent.start_link(fn -> %{next: 1, open: []} end)

    def close(pid), do: Agent.stop(pid)

    def command(pid, method, params, session_id, _timeout_ms, _grace_ms) do
      if c = Process.whereis(:tab_affinity_collector),
        do: send(c, {:cdp, method, params, session_id})

      run(pid, method, params)
    end

    defp run(pid, "Target.createTarget", _params) do
      id =
        Agent.get_and_update(pid, fn s ->
          tid = "T#{s.next}"
          {tid, %{s | next: s.next + 1, open: s.open ++ [tid]}}
        end)

      {:ok, %{"targetId" => id}}
    end

    defp run(_pid, "Target.attachToTarget", %{targetId: tid}),
      do: {:ok, %{"sessionId" => "S-#{tid}"}}

    defp run(pid, "Target.closeTarget", %{targetId: tid}) do
      Agent.update(pid, fn s -> %{s | open: List.delete(s.open, tid)} end)
      {:ok, %{}}
    end

    defp run(pid, "Target.getTargets", _params) do
      infos =
        pid
        |> Agent.get(& &1.open)
        |> Enum.map(fn tid ->
          %{
            "targetId" => tid,
            "type" => "page",
            "url" => "https://example.com/#{tid}",
            "title" => tid
          }
        end)

      {:ok, %{"targetInfos" => infos}}
    end

    defp run(_pid, _method, _params), do: {:ok, %{}}
  end

  @chat_a {"telegram", "chat-a", :root}
  @chat_b {"companion", "chat-b", :root}
  @job_run {:scheduled_job, "job-1", "run-1"}

  setup do
    Process.register(self(), :tab_affinity_collector)

    on_exit(fn ->
      if Process.whereis(:tab_affinity_collector),
        do: Process.unregister(:tab_affinity_collector)
    end)

    :ok
  end

  defp start_server(config) do
    start_supervised!(
      {ProfileServer,
       owner_key: "owner",
       profile_name: "fermix",
       profile: %{mode: :managed, headless: true, cdp_port: :auto},
       config: config,
       launcher: Launcher,
       connection: Connection}
    )
  end

  defp req(pid, conversation, action, args) do
    ProfileServer.request(pid, %{
      action: action,
      args: args,
      context: %{agent_name: "t", tab_affinity: conversation}
    })
  end

  # `observe: false`: this table has no page to look at.
  defp open!(pid, conversation) do
    args = %{"url" => "https://example.com/", "observe" => false}
    assert {:ok, %{"target" => target}} = req(pid, conversation, "open", args)
    target
  end

  # A click with no `target`, and the sessions its mouse events were sent on.
  defp click(pid, conversation) do
    flush_cdp()
    result = req(pid, conversation, "act", %{"kind" => "click_coords", "x" => 5, "y" => 5})
    {result, mouse_sessions()}
  end

  defp mouse_sessions do
    receive do
      {:cdp, "Input.dispatchMouseEvent", _params, session} -> [session | mouse_sessions()]
      {:cdp, _method, _params, _session} -> mouse_sessions()
    after
      0 -> []
    end
  end

  defp flush_cdp do
    receive do
      {:cdp, _method, _params, _session} -> flush_cdp()
    after
      0 -> :ok
    end
  end

  defp tabs(pid, conversation) do
    assert {:ok, %{"tabs" => rows}} = req(pid, conversation, "tabs", %{})
    rows
  end

  test "two conversations interleaving open and click never touch each other's tab" do
    {:ok, config} = Config.current()
    pid = start_server(config)

    tab_a = open!(pid, @chat_a)
    tab_b = open!(pid, @job_run)
    assert tab_a != tab_b

    assert {{:ok, %{"target" => ^tab_a}}, [_ | _] = sessions} = click(pid, @chat_a)
    assert Enum.uniq(sessions) == ["S-T1"]

    assert {{:ok, %{"target" => ^tab_b}}, sessions} = click(pid, @job_run)
    assert Enum.uniq(sessions) == ["S-T2"]

    # The scheduled run opening another page moves nobody else's tab.
    tab_b2 = open!(pid, @job_run)
    assert {{:ok, %{"target" => ^tab_a}}, sessions} = click(pid, @chat_a)
    assert Enum.uniq(sessions) == ["S-T1"]
    assert {{:ok, %{"target" => ^tab_b2}}, _sessions} = click(pid, @job_run)
  end

  test "a conversation with no tab of its own is never handed another's, and opens its own" do
    {:ok, config} = Config.current()
    pid = start_server(config)

    tab_a = open!(pid, @chat_a)
    tab_b = open!(pid, @job_run)

    assert {{:error, %{code: "no_tab", message: message}}, []} = click(pid, @chat_b)
    assert message =~ "`open`"

    # `navigate` with no tab of its own opens one rather than borrowing a tab.
    flush_cdp()
    args = %{"url" => "https://example.com/c", "observe" => false}
    assert {:ok, %{"target" => tab_c}} = req(pid, @chat_b, "navigate", args)
    assert_received {:cdp, "Target.createTarget", _params, _session}
    refute tab_c in [tab_a, tab_b]

    assert {{:ok, %{"target" => ^tab_c}}, sessions} = click(pid, @chat_b)
    assert Enum.uniq(sessions) == ["S-T3"]
  end

  test "closing one conversation's tab leaves the other's where it was" do
    {:ok, config} = Config.current()
    pid = start_server(config)

    tab_a = open!(pid, @chat_a)
    tab_b = open!(pid, @chat_b)

    flush_cdp()
    assert {:ok, %{"closed" => ^tab_a}} = req(pid, @chat_a, "close", %{})
    assert_received {:cdp, "Target.closeTarget", %{targetId: "T1"}, _session}

    assert {{:ok, %{"target" => ^tab_b}}, sessions} = click(pid, @chat_b)
    assert Enum.uniq(sessions) == ["S-T2"]
    assert {{:error, %{code: "no_tab"}}, []} = click(pid, @chat_a)
  end

  test "after closing its current tab a conversation acts on its previous one" do
    {:ok, config} = Config.current()
    pid = start_server(config)

    first = open!(pid, @chat_a)
    _other = open!(pid, @chat_b)
    second = open!(pid, @chat_a)

    assert {:ok, %{"closed" => ^second}} = req(pid, @chat_a, "close", %{})
    assert {{:ok, %{"target" => ^first}}, _sessions} = click(pid, @chat_a)
  end

  test "`target` names any tab in the shared browser, and focusing one makes it the caller's" do
    {:ok, config} = Config.current()
    pid = start_server(config)

    tab_a = open!(pid, @chat_a)
    tab_b = open!(pid, @chat_b)

    args = %{"kind" => "click_coords", "x" => 5, "y" => 5, "target" => tab_a}
    assert {:ok, %{"target" => ^tab_a}} = req(pid, @chat_b, "act", args)
    # Naming a tab once does not move the caller's own.
    assert {{:ok, %{"target" => ^tab_b}}, _sessions} = click(pid, @chat_b)

    assert {:ok, %{"target" => ^tab_a}} = req(pid, @chat_b, "focus", %{"target" => tab_a})
    assert {{:ok, %{"target" => ^tab_a}}, _sessions} = click(pid, @chat_b)
    # The tab's opener keeps it too.
    assert {{:ok, %{"target" => ^tab_a}}, _sessions} = click(pid, @chat_a)
  end

  test "max_tabs counts every conversation's tabs, and `tabs` lists them all, marking the caller's" do
    {:ok, config} = Config.current(max_tabs: 2)
    pid = start_server(config)

    tab_a = open!(pid, @chat_a)
    tab_b = open!(pid, @chat_b)
    tab_job = open!(pid, @job_run)

    # Three tabs over a cap of two: the oldest, chat A's, is closed.
    assert_received {:cdp, "Target.closeTarget", %{targetId: "T1"}, _session}

    rows = tabs(pid, @chat_b)
    assert Enum.map(rows, & &1["target"]) |> Enum.sort() == Enum.sort([tab_b, tab_job])
    refute Enum.any?(rows, &(&1["target"] == tab_a))

    marked = Map.new(rows, &{&1["target"], &1["this_conversation"]})
    assert marked == %{tab_b => true, tab_job => false}
  end
end
