defmodule FermixCore.Browser.TabCapTest do
  # Drives the real `open` path against an injected launcher + stateful fake CDP
  # connection that tracks live targets, proving a managed Chrome never grows
  # past `max_tabs` live tabs (the "too many Chrome tabs eating RAM" leak).
  # async: false — registers a global collector for dispatched CDP calls.
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.ProfileServer

  defmodule CapLauncher do
    # A managed launch that yields a usable runtime; the fake connection ignores
    # the ws_url, so no real Chrome is ever spawned.
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

  # Models Chrome's target table: createTarget adds a tab, closeTarget removes
  # one, getTargets lists the live set — so the server's tab bookkeeping is
  # exercised end to end. Every dispatched method is mirrored to the collector.
  defmodule CapConnection do
    use Agent

    def start_link(_url, opts),
      do: Agent.start_link(fn -> %{owner: Keyword.get(opts, :owner), next: 1, open: []} end)

    def close(pid), do: Agent.stop(pid)

    def command(pid, method, params, _session_id, _timeout_ms, _grace_ms) do
      if c = Process.whereis(:cap_collector), do: send(c, {:cdp, method, params})
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

  setup do
    Process.register(self(), :cap_collector)
    on_exit(fn -> if Process.whereis(:cap_collector), do: Process.unregister(:cap_collector) end)
    :ok
  end

  defp start_server(config) do
    start_supervised!(
      {ProfileServer,
       owner_key: "owner-test",
       profile_name: "fermix",
       profile: %{mode: :managed, headless: true, cdp_port: :auto},
       config: config,
       launcher: CapLauncher,
       connection: CapConnection}
    )
  end

  defp open(pid),
    do:
      ProfileServer.request(pid, %{
        action: "open",
        args: %{"url" => "https://example.com/"},
        context: %{agent_name: "t"}
      })

  defp tabs(pid),
    do: ProfileServer.request(pid, %{action: "tabs", args: %{}, context: %{agent_name: "t"}})

  test "open beyond max_tabs evicts the oldest non-active tabs, bounding live tabs" do
    {:ok, config} = Config.current(max_tabs: 3)
    pid = start_server(config)

    for _ <- 1..5, do: assert({:ok, _} = open(pid))

    # Cap is 3; the two oldest tabs (T1 then T2) were closed as T4 and T5 opened.
    assert_received {:cdp, "Target.closeTarget", %{targetId: "T1"}}
    assert_received {:cdp, "Target.closeTarget", %{targetId: "T2"}}

    # Live tab count never exceeds the cap.
    assert {:ok, %{"tabs" => live}} = tabs(pid)
    assert length(live) == 3
  end

  test "a managed Chrome at the cap stays at the cap across many opens" do
    {:ok, config} = Config.current(max_tabs: 2)
    pid = start_server(config)

    for _ <- 1..8, do: assert({:ok, _} = open(pid))

    assert {:ok, %{"tabs" => live}} = tabs(pid)
    assert length(live) == 2
  end
end
