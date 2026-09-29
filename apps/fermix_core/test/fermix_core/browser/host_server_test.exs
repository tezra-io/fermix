defmodule FermixCore.Browser.HostServerTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Backend
  alias FermixCore.Browser.Capabilities
  alias FermixCore.Browser.CDP
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.ProfileServer
  alias FermixCore.Browser.TurnMarker
  alias FermixCore.BrowserHost.Link
  alias FermixTestSupport.FakeBrowserHostConnection

  # A backend whose runtime always comes up and whose every operation answers,
  # so what the server refuses on its own is visible: it never reaches here.
  defmodule UpBackend do
    @behaviour FermixCore.Browser.Backend

    @ops ~w(open navigate snapshot tabs focus close screenshot pdf console dialog cookies storage
            upload download act webmcp)a

    @impl true
    def init(opts), do: %{test_pid: Keyword.fetch!(opts, :test_pid)}
    @impl true
    def status(_state), do: %{"running" => true, "tabs" => 1}
    @impl true
    def start(_context, state), do: {:ok, state}
    @impl true
    def stop(state), do: state
    @impl true
    def handle_message(_message, state), do: state
    @impl true
    def console_buffer(_state), do: []

    for op <- @ops do
      @impl true
      def unquote(op)(_args, _context, state) do
        send(state.test_pid, {:backend_asked, unquote(op)})
        {:ok, %{"ok" => true}, state}
      end
    end
  end

  @pane %{mode: :fermix_app, headless: :auto, cdp_port: :auto}

  defp start_server(opts) do
    {:ok, config} = Config.current(%{})

    defaults = [owner_key: "owner-pane", profile_name: "fermix", profile: @pane, config: config]
    spec = {ProfileServer, Keyword.merge(defaults, opts)}

    start_supervised!(Supervisor.child_spec(spec, restart: :temporary))
  end

  # An isolated host, attached to a fake connection and reporting available.
  defp usable_host(responses \\ %{}) do
    {:ok, connection} = FakeBrowserHostConnection.start_link(responses)
    host = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    endpoint = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(endpoint, :kill) end)
    :ok = HostAvailability.listening(host, endpoint)
    :ok = HostAvailability.attached(host, connection, 1)
    :ok = HostAvailability.report(host, true, nil)
    {host, connection}
  end

  defp req(pid, action, args \\ %{}),
    do: ProfileServer.request(pid, %{action: action, args: args, context: %{agent_name: "t"}})

  defp page(url, opts \\ []) do
    %{
      "url" => url,
      "title" => Keyword.get(opts, :title, "Example"),
      "ready_state" => "complete",
      "nodes" => [
        %{
          "nodeId" => "1",
          "role" => %{"value" => "RootWebArea"},
          "name" => %{"value" => Keyword.get(opts, :title, "Example")},
          "childIds" => ["2"]
        },
        %{
          "nodeId" => "2",
          "backendDOMNodeId" => 7,
          "role" => %{"value" => "button"},
          "name" => %{"value" => "Go"}
        }
      ]
    }
  end

  test "the fermix_app mode is the host backend, and every other mode is CDP's" do
    assert Backend.for_mode(:fermix_app) == FermixCore.Browser.HostServer

    for mode <- [:managed, :existing_session, :remote_cdp, :attached_tab] do
      assert Backend.for_mode(mode) == CDP.Backend
    end
  end

  test "the app's pane is a whole browser of Fermix's own, without WebMCP" do
    caps = Capabilities.for_mode(:fermix_app)

    for capability <- [
          :new_tab,
          :close_tab,
          :focus_tab,
          :cookies,
          :downloads,
          :download_redirect,
          :target_discovery,
          :tab_cap
        ] do
      assert Map.fetch!(caps, capability), "#{capability} is withheld from the app's pane"
    end

    refute caps.webmcp
    refute caps.target_attach

    assert Map.keys(caps) |> Enum.sort() ==
             Capabilities.for_mode(:managed) |> Map.keys() |> Enum.sort()
  end

  test "the server refuses WebMCP on the app's pane before the backend is asked" do
    pid = start_server(backend: UpBackend, test_pid: self())

    assert {:error, %Error{code: "unsupported_in_fermix_app"} = error} = req(pid, "webmcp")
    assert error.message =~ "snapshot"
    refute_received {:backend_asked, :webmcp}

    assert {:ok, _} = req(pid, "snapshot")
    assert_received {:backend_asked, :snapshot}
  end

  # ── a task on the host ───────────────────────────────────────────────────

  test "a task opens a tab on the host, and its tab id is scoped to the connection it opened on" do
    {host, connection} =
      usable_host(%{
        "tab.open" => fn payload ->
          assert payload["url"] == "about:blank"
          assert payload["observe"] == true
          assert String.starts_with?(payload["task_id"], "task-")
          assert String.starts_with?(payload["download_dir"], "/")
          assert payload["visible"] == true

          {:ok,
           %{
             "tab_id" => "t1",
             "url" => "about:blank",
             "title" => "",
             "page" => page("about:blank")
           }}
        end
      })

    pid = start_server(host_availability: host)

    assert {:ok, result} = req(pid, "open", %{"url" => "about:blank"})
    assert result["target"] == "h1:t1"
    assert result["page"] == "changed"
    assert result["snapshot"] =~ "<browser_page_content>"
    assert [{"tab.open", _payload}] = FakeBrowserHostConnection.requests(connection)
  end

  test "a task on the visible profile tells the app to show its pane and window" do
    {host, connection} =
      usable_host(%{
        "tab.open" => fn payload ->
          assert payload["visible"] == true
          {:ok, %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}}
        end
      })

    pid = start_server(host_availability: host, profile_name: "fermix_visible")

    assert {:ok, _result} = req(pid, "open", %{"url" => "about:blank", "observe" => false})
    assert [{"tab.open", payload}] = FakeBrowserHostConnection.requests(connection)
    assert payload["visible"] == true
  end

  test "a task on the headless profile never tells the app to show its pane" do
    {host, connection} =
      usable_host(%{
        "tab.open" => fn payload ->
          refute Map.has_key?(payload, "visible")
          {:ok, %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}}
        end
      })

    pid = start_server(host_availability: host, profile_name: "fermix_headless")

    assert {:ok, _result} = req(pid, "open", %{"url" => "about:blank", "observe" => false})
    assert [{"tab.open", payload}] = FakeBrowserHostConnection.requests(connection)
    refute Map.has_key?(payload, "visible")
  end

  test "an explicit headless override keeps the automatic profile's pane unseen" do
    prior = System.get_env("FERMIX_BROWSER_HEADLESS")
    System.put_env("FERMIX_BROWSER_HEADLESS", "1")

    on_exit(fn ->
      case prior do
        nil -> System.delete_env("FERMIX_BROWSER_HEADLESS")
        value -> System.put_env("FERMIX_BROWSER_HEADLESS", value)
      end
    end)

    {host, connection} =
      usable_host(%{
        "tab.open" => fn payload ->
          refute Map.has_key?(payload, "visible")
          {:ok, %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}}
        end
      })

    pid = start_server(host_availability: host)

    assert {:ok, _result} = req(pid, "open", %{"url" => "about:blank", "observe" => false})
    assert [{"tab.open", payload}] = FakeBrowserHostConnection.requests(connection)
    refute Map.has_key?(payload, "visible")
  end

  test "an act on an identical page renders through the shared snapshot renderer and answers unchanged" do
    {host, connection} =
      usable_host(%{
        "tab.open" =>
          {:ok,
           %{
             "tab_id" => "t1",
             "url" => "about:blank",
             "title" => "",
             "page" => page("about:blank")
           }},
        "page.act" =>
          {:ok, %{"url" => "about:blank", "title" => "", "page" => page("about:blank")}}
      })

    pid = start_server(host_availability: host)

    assert {:ok, opened} = req(pid, "open", %{"url" => "about:blank"})
    assert opened["target"] == "h1:t1"

    assert {:ok, acted} =
             req(pid, "act", %{"target" => "h1:t1", "kind" => "click", "ref" => "button_1"})

    assert acted["page"] == "unchanged"
    refute Map.has_key?(acted, "snapshot")

    [{"tab.open", _}, {"page.act", act_payload}] = FakeBrowserHostConnection.requests(connection)
    assert act_payload["ref"] == 7
    assert act_payload["kind"] == "click"
  end

  test "an unknown tab is refused locally, before anything is asked of the app" do
    {host, connection} = usable_host()
    pid = start_server(host_availability: host)

    assert {:error, %Error{code: "tab_not_found"}} =
             req(pid, "act", %{"target" => "h1:t1", "kind" => "click", "ref" => "button_1"})

    assert FakeBrowserHostConnection.requests(connection) == []
  end

  test "a ref from no snapshot at all is refused as stale, without asking the app" do
    {host, connection} =
      usable_host(%{
        "tab.open" => {:ok, %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}}
      })

    pid = start_server(host_availability: host)
    assert {:ok, _} = req(pid, "open", %{"url" => "about:blank", "observe" => false})

    assert {:error, %Error{code: "stale_ref"}} =
             req(pid, "act", %{"target" => "h1:t1", "kind" => "click", "ref" => "button_1"})

    assert [{"tab.open", _}] = FakeBrowserHostConnection.requests(connection)
  end

  test "the app's cap_reached answer becomes a sentence naming the task's own cap" do
    {host, _connection} =
      usable_host(%{
        "tab.open" => {:error, %{"reason" => "cap_reached", "message" => "task owns 10 tabs"}}
      })

    pid = start_server(host_availability: host)

    assert {:error, %Error{code: "cap_reached", message: message}} =
             req(pid, "open", %{"url" => "about:blank"})

    assert message =~ "already has as many tabs open"
  end

  # ── ending a task ────────────────────────────────────────────────────────

  test "stopping a task with nothing open asks the app for nothing" do
    {host, connection} = usable_host()
    pid = start_server(host_availability: host)

    assert {:ok, %{"stopped" => true}} = req(pid, "stop")
    assert FakeBrowserHostConnection.releases(connection) == []
  end

  test "a task's tabs are released once, when it ends" do
    {host, connection} =
      usable_host(%{
        "tab.open" => {:ok, %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}}
      })

    pid = start_server(host_availability: host)
    assert {:ok, _} = req(pid, "open", %{"url" => "about:blank", "observe" => false})
    assert {:ok, %{"stopped" => true}} = req(pid, "stop")

    assert [released_id] = FakeBrowserHostConnection.releases(connection)
    assert String.starts_with?(released_id, "task-")
  end

  # ── a pane that goes away mid-task (BROWSER-4, BROWSER-5) ───────────────

  test "a pane whose connection goes down is reaped with host_lost, and marks the turn" do
    {host, connection} =
      usable_host(%{
        "tab.open" => {:ok, %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}}
      })

    pid = start_server(host_availability: host)
    ref = Process.monitor(pid)

    assert {:ok, _} = req(pid, "open", %{"url" => "about:blank", "observe" => false})

    Process.exit(connection, :kill)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert %Error{code: "host_lost", message: message} = TurnMarker.lookup("owner-pane", self())
    assert message =~ "the app disconnected"
  end

  test "the app is quitting while a request is out fails it with a sentence, and reaps the task" do
    host = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    endpoint = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(endpoint, :kill) end)
    :ok = HostAvailability.listening(host, endpoint)

    connection =
      spawn(fn ->
        receive do
          {:browser_host_request, from, ref, _task_id, "tab.open", _payload} ->
            Link.answer(
              from,
              ref,
              {:ok, %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}}
            )
        end

        receive do
          {:browser_host_request, from, _ref, _task_id, "page.act", _payload} ->
            Link.stopping(from, self())
        end

        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(connection, :kill) end)
    :ok = HostAvailability.attached(host, connection, 1)
    :ok = HostAvailability.report(host, true, nil)

    pid = start_server(host_availability: host)
    ref = Process.monitor(pid)

    assert {:ok, _} = req(pid, "open", %{"url" => "about:blank", "observe" => false})

    assert {:error, %Error{code: "host_lost", message: message}} =
             req(pid, "act", %{"target" => "h1:t1", "kind" => "press", "key" => "Enter"})

    assert message =~ "the app is quitting"
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "the person cancelling from the app fails the task with its own sentence, and reaps it" do
    host = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    endpoint = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(endpoint, :kill) end)
    :ok = HostAvailability.listening(host, endpoint)

    connection =
      spawn(fn ->
        receive do
          {:browser_host_request, from, ref, _task_id, "tab.open", _payload} ->
            Link.answer(
              from,
              ref,
              {:ok, %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}}
            )
        end

        receive do
          {:browser_host_request, from, _ref, _task_id, "page.act", _payload} ->
            Link.cancelled(from, self(), "cancelled by the person")
        end

        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(connection, :kill) end)
    :ok = HostAvailability.attached(host, connection, 1)
    :ok = HostAvailability.report(host, true, nil)

    pid = start_server(host_availability: host)
    ref = Process.monitor(pid)

    assert {:ok, _} = req(pid, "open", %{"url" => "about:blank", "observe" => false})

    assert {:error, %Error{code: "cancelled", message: message}} =
             req(pid, "act", %{"target" => "h1:t1", "kind" => "press", "key" => "Enter"})

    assert message == "The person cancelled the browser task in the Fermix app."
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "a pane the app reports unavailable is lost with the app's own reason" do
    {host, _connection} = usable_host()
    :ok = HostAvailability.report(host, false, "the pane was closed")

    pid = start_server(host_availability: host)

    assert {:error, %Error{code: "host_lost", message: message}} = req(pid, "tabs")
    assert message =~ "no longer available: the pane was closed"
  end

  test "a pane with no host at all is lost before it starts" do
    host = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    pid = start_server(host_availability: host)

    assert {:error, %Error{code: "host_lost", message: message}} = req(pid, "start")
    assert message =~ "nothing in this engine serves it"
  end
end
