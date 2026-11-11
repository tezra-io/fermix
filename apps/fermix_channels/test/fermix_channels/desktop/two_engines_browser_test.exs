defmodule FermixChannels.Desktop.TwoEnginesBrowserTest do
  # M97 §6.4: Fermix on the server drives a computer's browser, over the real
  # link. The server keeps the `browser` tool's own half (its arguments, the
  # owner's approval of a sign-in in the chat, a fill that submits) and each
  # request a profile answers is one invocation the computer serves through
  # its own `Routing`, `ProfileManager` and profile server, from the process
  # that stands for the server's turn there.
  #
  # The computer's browser is its own stack, under this test's names and its
  # own configuration (`Desktop.Invoke`'s `:browser`). No real Chrome runs:
  # a Chrome profile there is driven by `FakeChrome` (a `Browser.Backend`
  # that reports each operation and writes its captures and downloads into
  # the computer's own browser folder), and the Fermix app's pane is the real
  # `HostServer` on a fake app connection (`FakeBrowserHostConnection`). So
  # what is not covered here is Chrome's own protocol and the app's own
  # wire, which their own suites hold. The server's home is a temporary
  # `FERMIX_HOME` of this test's, where its artifacts land and its uploads
  # come from. async: false: the relay's dial names are VM-wide, and so is
  # `FERMIX_HOME`.
  use ExUnit.Case, async: false

  alias FermixChannels.Desktop.Offers
  alias FermixChannels.Test.TwoEngines
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Browser.TurnMarker
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Computers
  alias FermixCore.Computers.Capabilities.Browser, as: BrowserCapability
  alias FermixCore.Computers.Choice
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Journal
  alias FermixCore.Computers.Outcome
  alias FermixCore.Tools.Browser, as: BrowserTool
  alias FermixTestSupport.FakeBrowserHostConnection
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @capture "PNG-" <> String.duplicate("leaf", 70_000)
  @report "%PDF-1.7 allotment orders"
  @receipts "date,item,total\n2026-10-30,seed potatoes,14.20\n"

  defmodule FakeChrome do
    @moduledoc """
    Chrome on the computer, as far as its profile server can tell: each
    operation tells the test what it was asked, for which conversation and
    from which process, and a capture or a download is a file it writes in
    the computer's own browser folder.
    """
    @behaviour FermixCore.Browser.Backend

    alias FermixCore.Browser.Error

    @impl true
    def init(opts) do
      %{
        test: Keyword.fetch!(opts, :test_pid),
        dir: Keyword.fetch!(opts, :browser_dir),
        capture: Keyword.fetch!(opts, :capture),
        tabs: %{},
        current: %{},
        next: 1
      }
    end

    @impl true
    def status(state), do: %{"running" => true, "tabs" => map_size(state.tabs)}
    @impl true
    def start(_context, state), do: {:ok, state}
    @impl true
    def stop(state), do: state
    @impl true
    def handle_message(_message, state), do: state
    @impl true
    def console_buffer(_state), do: []

    @impl true
    def open(args, context, state) do
      id = "t#{state.next}"
      told(state, :open, args, context)

      state = %{
        state
        | next: state.next + 1,
          tabs: Map.put(state.tabs, id, args["url"]),
          current: Map.put(state.current, context.tab_affinity, id)
      }

      {:ok, look(id, args["url"]), state}
    end

    @impl true
    def navigate(args, context, state) do
      in_tab(args, context, state, :navigate, fn id, state ->
        {:ok, look(id, args["url"]), %{state | tabs: Map.put(state.tabs, id, args["url"])}}
      end)
    end

    @impl true
    def snapshot(args, context, state),
      do: in_tab(args, context, state, :snapshot, &{:ok, look(&1, &2.tabs[&1]), &2})

    @impl true
    def tabs(args, context, state) do
      told(state, :tabs, args, context)
      mine = state.current[context.tab_affinity]

      rows =
        for {id, url} <- Enum.sort(state.tabs),
            do: %{"target" => id, "url" => url, "this_conversation" => id == mine}

      {:ok, %{"ok" => true, "tabs" => rows}, state}
    end

    @impl true
    def act(%{"kind" => "get"} = args, context, state),
      do:
        in_tab(args, context, state, :act, fn _id, s ->
          {:ok, %{"ok" => true, "result" => "Orders"}, s}
        end)

    def act(args, context, state) do
      in_tab(args, context, state, :act, fn id, s ->
        {:ok, %{"ok" => true, "target" => id, "action" => args["kind"], "page" => "unchanged"}, s}
      end)
    end

    @impl true
    def screenshot(args, context, state) do
      in_tab(args, context, state, :screenshot, fn id, s ->
        path = write(s, ["artifacts", "owner", "screenshots", "#{id}.png"], s.capture)
        {:ok, %{"ok" => true, "target" => id, "path" => path, "mime_type" => "image/png"}, s}
      end)
    end

    @impl true
    def pdf(args, context, state) do
      in_tab(args, context, state, :pdf, fn id, s ->
        path = write(s, ["artifacts", "owner", "pdf", "#{id}.pdf"], "%PDF-1.7 allotment orders")

        {:ok, %{"ok" => true, "target" => id, "path" => path, "mime_type" => "application/pdf"},
         s}
      end)
    end

    @impl true
    def download(args, context, state) do
      told(state, :download, args, context)
      guid = "7f1c2a9e-5b3d-4e8f-a1c6-0d2e4f6a8b10"

      path =
        write(
          state,
          ["downloads", "owner", guid],
          "date,item,total\n2026-10-30,seed potatoes,14.20\n"
        )

      {:ok,
       %{
         "ok" => true,
         "guid" => guid,
         "path" => path,
         "url" => "https://allotment.example.com/receipts.csv",
         "suggested_filename" => "receipts.csv"
       }, state}
    end

    @impl true
    def upload(args, context, state) do
      in_tab(args, context, state, :upload, fn id, s ->
        send(s.test, {:uploaded, args["path"], File.read!(args["path"])})
        {:ok, %{"ok" => true, "target" => id, "uploaded" => Path.basename(args["path"])}, s}
      end)
    end

    for op <- ~w(focus close console dialog cookies storage webmcp)a do
      @impl true
      def unquote(op)(args, context, state) do
        told(state, unquote(op), args, context)
        {:ok, %{"ok" => true, "done" => unquote(Atom.to_string(op))}, state}
      end
    end

    defp in_tab(args, context, state, op, fun) do
      told(state, op, args, context)

      case args["target"] || state.current[context.tab_affinity] do
        nil -> {:error, Error.new("no_tab", "This conversation has no tab yet; open one."), state}
        id -> fun.(id, state)
      end
    end

    defp told(state, op, args, context),
      do: send(state.test, {:chrome, op, args, context.tab_affinity, context.caller})

    defp look(id, url) do
      %{
        "ok" => true,
        "target" => id,
        "url" => url,
        "title" => "Allotment orders",
        "snapshot" => ~s(- heading "Orders" [ref=heading_1]),
        "page" => "changed",
        "ready_state" => "complete"
      }
    end

    defp write(state, parts, bytes) do
      path = Path.join([state.dir | parts])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
      path
    end
  end

  setup context do
    server_home = SafeRm.make_tmp_dir!("two_engines_browser_server")
    File.mkdir_p!(Path.join(server_home, "workspace"))
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", server_home)

    on_exit(fn ->
      restore_home(previous)
      SafeRm.rm_rf!(server_home)
    end)

    sid = "two-engines-browser-#{System.unique_integer([:positive])}"
    agent = "main-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], agent: agent)

    computer_dir = SafeRm.make_tmp_dir!("two_engines_computer_browser")
    on_exit(fn -> SafeRm.rm_rf!(computer_dir) end)
    browser = computer_browser!(computer_dir, context[:pane] == true)

    engines =
      TwoEngines.start!(offers: [:browser], browser: fn -> {:ok, browser.seams} end)

    turns = server_turns!()
    pending = start_supervised!({Pending, name: nil}, id: make_ref())

    %{
      owner: self(),
      e: engines,
      sid: sid,
      agent: agent,
      server: server_home,
      browser: browser,
      computer_dir: computer_dir,
      turns: turns,
      pending: pending
    }
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)

  # The computer's own browser: its profiles' registry and manager, its
  # pane's host, its turn marker and its held turns, and the configuration it
  # serves with. A Chrome profile is `FakeChrome`; with `pane?` the Fermix
  # app's pane is attached instead, on a fake app connection.
  defp computer_browser!(dir, pane?) do
    n = System.unique_integer([:positive])
    registry = :"computer_browser_registry_#{n}"
    profiles = :"computer_browser_profiles_#{n}"
    manager = :"computer_browser_manager_#{n}"
    marker = :"computer_browser_marker_#{n}"
    turns = %{registry: :"computer_browser_turns_#{n}", supervisor: :"computer_browser_held_#{n}"}

    start_supervised!({Elixir.Registry, keys: :unique, name: registry}, id: registry)
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: profiles}, id: profiles)
    host = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    start_supervised!({TurnMarker, name: marker}, id: marker)
    start_supervised!({Elixir.Registry, keys: :unique, name: turns.registry}, id: turns.registry)

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: turns.supervisor},
      id: turns.supervisor
    )

    chrome =
      if pane?,
        do: [],
        else: [backend: FakeChrome, test_pid: self(), capture: @capture]

    start_supervised!(
      {ProfileManager,
       name: manager,
       dynamic_supervisor: profiles,
       registry: registry,
       child_opts:
         [host_availability: host, turn_marker: marker, browser_dir: Path.join(dir, "browser")] ++
           chrome},
      id: manager
    )

    connection = if pane?, do: attach_app!(host)
    {:ok, config} = Config.current(%{launch_app: false}, engine_web_port: 4_102)

    %{
      host: host,
      connection: connection,
      seams: %{
        config: config,
        browser_dir: Path.join(dir, "browser"),
        uploads: BrowserCapability.uploads_dir(Path.join(dir, "workspace")),
        turns: turns,
        routing: [registry: registry, host_availability: host],
        manager: [registry: registry, server: manager],
        turn_marker: marker
      }
    }
  end

  defp attach_app!(host) do
    {:ok, connection} = FakeBrowserHostConnection.start_link(app_answers())
    on_exit(fn -> Process.exit(connection, :kill) end)
    endpoint = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(endpoint, :kill) end)
    :ok = HostAvailability.listening(host, endpoint)
    :ok = HostAvailability.attached(host, connection, 1, 2)
    :ok = HostAvailability.report(host, true, nil)
    connection
  end

  # The server's turns whose browser runs on a computer, under this test's
  # names. Started after the engines, so they stop first.
  defp server_turns! do
    n = System.unique_integer([:positive])
    turns = %{registry: :"server_browser_turns_#{n}", supervisor: :"server_browser_turn_sup_#{n}"}
    start_supervised!({Elixir.Registry, keys: :unique, name: turns.registry}, id: turns.registry)

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: turns.supervisor},
      id: turns.supervisor
    )

    turns
  end

  # An owner's chat turn on the server, its session the turn's own (each turn
  # is a process of its own here, as in the agent loop); its computers are
  # read at each call, so one that went away is away in the next call's
  # context.
  defp turn(ctx, more \\ %{}) do
    test = ctx.owner

    Map.merge(
      %{
        source_trust: :operator,
        computer_use_origin: :interactive,
        session_id: "#{ctx.sid}-#{:erlang.phash2(self())}",
        agent_name: ctx.agent,
        conversation_key: {"telegram", ctx.sid, :root},
        chat_type: "private",
        outside_sources: MapSet.new(),
        computers: [TwoEngines.computer(ctx.e)],
        computer_call_opts: TwoEngines.call_opts(ctx.e),
        browser_turns: ctx.turns,
        access_pending: ctx.pending,
        approval_fn: fn %{access_sensitive: id} ->
          send(test, {:asked, self(), id})
          {:ok, "tok-1", :new}
        end,
        reply_fn: fn part ->
          send(test, {:prompt, part})
          :ok
        end
      },
      more
    )
  end

  defp call(ctx, args, more \\ %{}) do
    Builtin.from_tool_module(BrowserTool)
    |> Capability.execute(args, turn(ctx, more))
  end

  defp on_mac(args), do: Map.put(args, "computer", "studio Mac")

  # One server turn: a process of its own that makes `fun`'s calls, which ends
  # when they are made, as a turn does.
  defp in_turn(fun), do: fun |> Task.async() |> Task.await(30_000)

  defp decoded({:ok, %{success: true, output: output}}), do: Jason.decode!(output)

  defp exec_event do
    assert_receive {:telemetry, [:fermix, :tool, :exec], _measure, %{tool: "browser"} = metadata},
                   10_000

    metadata
  end

  # The computer's journal, newest first, without the turns' ends
  # (`browser.end`), which the tests that need them read on their own.
  defp journal(e), do: Enum.reject(whole_journal(e), &(&1.op == "browser.end"))

  defp whole_journal(e) do
    {:ok, %{entries: entries}} = Journal.list(Journal.dir(e.root))
    entries
  end

  defp ops(e), do: e |> journal() |> Enum.map(& &1.op) |> Enum.reverse()

  describe "each kind of request crosses the link and is served by the computer's browser" do
    test "a turn's requests reach the computer's Chrome in its own tab, from one process there",
         ctx do
      results =
        in_turn(fn ->
          [
            call(ctx, on_mac(%{"action" => "open", "url" => "https://allotment.example.com"})),
            call(ctx, %{"action" => "navigate", "url" => "https://allotment.example.com/orders"}),
            call(ctx, %{"action" => "snapshot"}),
            call(ctx, %{"action" => "tabs"}),
            call(ctx, %{"action" => "act", "kind" => "click", "ref" => "button_1"}),
            call(ctx, %{"action" => "act", "kind" => "get", "field" => "title"}),
            call(ctx, %{
              "action" => "act",
              "kind" => "fill_form",
              "fields" => [%{"ref" => "textbox_1", "text" => "12 seed potatoes"}],
              "submit" => true
            }),
            call(ctx, %{"action" => "cookies"}),
            call(ctx, %{"action" => "storage", "key" => "basket", "value" => "3"}),
            call(ctx, %{"action" => "console"}),
            call(ctx, %{"action" => "dialog", "decision" => "accept"}),
            call(ctx, %{"action" => "webmcp", "op" => "call", "name" => "add_to_basket"}),
            call(ctx, %{"action" => "status"})
          ]
        end)

      [opened | _rest] = decoded_all = Enum.map(results, &decoded/1)
      assert opened["computer"] == "studio Mac"
      assert opened["backend"] == "cdp"
      assert Enum.all?(Enum.drop(decoded_all, 1), &(&1["computer"] == "studio Mac"))

      # Every request came from the one process that stands for the turn on
      # the computer, in the conversation's own tab.
      chrome = drain_chrome([])
      assert [{:open, _args, affinity, caller} | _more] = chrome
      assert Enum.all?(chrome, fn {_op, _args, a, c} -> a == affinity and c == caller end)
      assert elem(affinity, 0) == "server"
      refute caller == self()

      assert Enum.map(chrome, &elem(&1, 0)) ==
               ~w(open navigate snapshot tabs act act act act cookies storage console dialog webmcp)a

      # One journal entry per request; a fill that submits is two.
      assert ops(ctx.e) == [
               "browser.open",
               "browser.navigate",
               "browser.snapshot",
               "browser.tabs",
               "browser.act",
               "browser.act.read",
               "browser.act",
               "browser.act",
               "browser.cookies",
               "browser.storage.write",
               "browser.console",
               "browser.dialog",
               "browser.webmcp.call",
               "browser.status"
             ]

      assert Enum.all?(journal(ctx.e), &(&1.status == "ok"))

      assert Enum.find(journal(ctx.e), &(&1.op == "browser.open")).target ==
               "open allotment.example.com"

      # One exec event per model call, under `browser`, naming the computer.
      for _call <- results do
        metadata = exec_event()
        assert metadata.computer == ctx.e.device_id
        assert metadata.invoke_status == :ok
        assert is_binary(metadata.invocation)
      end

      refute_received {:telemetry, [:fermix, :tool, :exec], _measure, _more}
    end

    test "a screenshot, a PDF and a download come back as bytes into the server's own folder",
         ctx do
      [shot, report, receipts] =
        in_turn(fn ->
          call(ctx, on_mac(%{"action" => "open", "url" => "https://allotment.example.com"}))

          [
            call(ctx, %{"action" => "screenshot"}),
            call(ctx, %{"action" => "pdf"}),
            call(ctx, %{"action" => "download"})
          ]
        end)

      assert {:ok, %{success: true, images: [image]} = shot_result} = shot
      assert image == %{type: :image, mime_type: "image/png", data: @capture}
      shot_said = Jason.decode!(shot_result.output)
      assert shot_said["computer"] == "studio Mac"
      assert_server_copy(ctx, shot_said["path"], ["artifacts", "owner", "screenshots"], @capture)

      report_said = decoded(report)
      assert_server_copy(ctx, report_said["path"], ["artifacts", "owner", "pdf"], @report)

      receipts_said = decoded(receipts)
      assert receipts_said["suggested_filename"] == "receipts.csv"
      assert_server_copy(ctx, receipts_said["path"], ["downloads", "owner"], @receipts)

      # Nothing of them stays in the computer's own browser folder.
      left = Path.wildcard(Path.join(ctx.computer_dir, "browser/**/*"))
      assert Enum.filter(left, &File.regular?/1) == []
      assert ops(ctx.e) == ~w(browser.open browser.screenshot browser.pdf browser.download)
    end

    test "an upload's file goes from the server's workspace to the computer's page", ctx do
      server_file = Path.join([ctx.server, "workspace", "seed-order.pdf"])
      File.write!(server_file, "%PDF-1.7 seed order")

      result =
        in_turn(fn ->
          call(ctx, on_mac(%{"action" => "open", "url" => "https://allotment.example.com"}))

          call(ctx, %{"action" => "upload", "ref" => "button_3", "path" => server_file})
        end)

      assert decoded(result)["uploaded"] == "seed-order.pdf"
      assert_received {:uploaded, staged, "%PDF-1.7 seed order"}
      refute staged == server_file

      assert String.starts_with?(
               staged,
               BrowserCapability.uploads_dir(Path.join(ctx.computer_dir, "workspace"))
             )

      # A file outside the server's workspace is refused here, as an upload here is.
      assert {:ok, %{success: false, error: error}} =
               call(
                 ctx,
                 on_mac(%{"action" => "upload", "ref" => "button_3", "path" => "/etc/hosts"})
               )

      assert error =~ "upload_blocked"
    end
  end

  describe "a sign-in on the computer's pane" do
    @describetag :pane

    test "the owner approves in the chat, and the pane types the login on the computer", ctx do
      turn =
        Task.async(fn ->
          opened = call(ctx, on_mac(%{"action" => "open", "url" => "https://example.com/login"}))
          target = decoded(opened)["target"]

          signed =
            call(ctx, %{
              "action" => "act",
              "kind" => "sign_in",
              "site" => "example.com",
              "username_ref" => "textbox_1",
              "password_ref" => "textbox_2",
              "target" => target
            })

          {opened, signed}
        end)

      assert_receive {:asked, waiter, id}, 10_000
      assert waiter == turn.pid
      assert_receive {:prompt, {:approval_prompt, text, "tok-1"}}
      assert text =~ "Sign in to example.com as person@example.com?"
      refute "page.sign_in" in request_types(ctx)

      assert :ok = AccessGate.confirm_in_call(id, ctx.pending)
      {opened, signed} = Task.await(turn, 30_000)

      assert decoded(opened)["backend"] == "fermix_app"
      said = decoded(signed)
      assert said["filled"] == ["username", "password"]
      assert said["username"] == "person@example.com"
      assert said["computer"] == "studio Mac"

      assert [{"tab.open", _open}, {"page.login_for", _lookup}, {"page.sign_in", typed}] =
               FakeBrowserHostConnection.requests(ctx.browser.connection)

      assert typed["username_ref"] == 11
      assert typed["password_ref"] == 12

      assert ops(ctx.e) == ~w(browser.open browser.login_for browser.sign_in)

      # The sign-in is one model call: one exec event, for both invocations.
      _open = exec_event()
      signing = exec_event()
      assert signing.computer == ctx.e.device_id
      assert signing.site == "example.com"
      refute_received {:telemetry, [:fermix, :tool, :exec], _measure, _more}

      # The turn ended normally without a hand-over: the computer ends its
      # pane task when it hears so.
      await_release(ctx)

      assert [%{op: "browser.end", status: "ok", target: "the end of a turn"} | _rest] =
               whole_journal(ctx.e)
    end

    test "the owner's no types nothing on the computer", ctx do
      turn =
        Task.async(fn ->
          call(ctx, on_mac(%{"action" => "open", "url" => "https://example.com/login"}))

          call(ctx, %{
            "action" => "act",
            "kind" => "sign_in",
            "site" => "example.com",
            "password_ref" => "textbox_2"
          })
        end)

      assert_receive {:asked, _waiter, id}, 10_000
      assert {:ok, :in_call} = AccessGate.deny(id, ctx.pending)
      assert {:ok, %{success: false, error: error}} = Task.await(turn, 30_000)
      assert error =~ "sign_in_denied"
      refute "page.sign_in" in request_types(ctx)
      assert ops(ctx.e) == ~w(browser.open browser.login_for)
    end

    test "a tab handed over outlives its turn, and the next turn takes it over", ctx do
      first =
        in_turn(fn ->
          call(ctx, on_mac(%{"action" => "open", "url" => "https://example.com/login"}))
          call(ctx, %{"action" => "handover"})
        end)

      assert decoded(first)["handed_over"] == true
      await_no_held_turns(ctx)
      assert FakeBrowserHostConnection.releases(ctx.browser.connection) == []

      # The next turn, in the same conversation, finds the same task's tab.
      second = in_turn(fn -> call(ctx, on_mac(%{"action" => "tabs"})) end)
      assert [%{"target" => "h1:t1"}] = decoded(second)["tabs"]

      await_release(ctx)
      assert length(FakeBrowserHostConnection.releases(ctx.browser.connection)) == 1
    end

    test "a sign-in is refused on the server for a turn the owner is not in, before any request",
         ctx do
      scheduled = %{
        trigger: "schedule",
        conversation_key: {:scheduled_job, "job-seed-check", "run-3"},
        computer_use_origin: :background
      }

      for more <- [%{computer_use_origin: :background}, scheduled] do
        assert {:ok, %{success: false, error: error}} =
                 call(
                   ctx,
                   on_mac(%{
                     "action" => "act",
                     "kind" => "sign_in",
                     "site" => "example.com",
                     "password_ref" => "textbox_2"
                   }),
                   more
                 )

        assert error =~ "sign_in_not_allowed"
      end

      assert journal(ctx.e) == []
    end
  end

  describe "the computer's own rules" do
    test "a sign-in reaching the computer from a turn the owner is not in is refused there",
         ctx do
      request = %{
        "action" => "login_for",
        "args" => %{"site" => "example.com"},
        "profile" => nil,
        "conversation" => "owner-YWxsb3RtZW50"
      }

      scheduled = %{session_id: ctx.sid, trigger: "schedule", source_trust: :operator}
      voice = %{session_id: ctx.sid, computer_use_origin: :voice, source_trust: :operator}

      assert {:error, %Outcome{status: :refused, refusal: :not_attended}} =
               Computers.call(
                 TwoEngines.computer(ctx.e),
                 BrowserCapability,
                 "browser.login_for",
                 request,
                 scheduled,
                 TwoEngines.call_opts(ctx.e)
               )

      assert {:error, %Outcome{status: :refused, refusal: :unavailable, message: message}} =
               Computers.call(
                 TwoEngines.computer(ctx.e),
                 BrowserCapability,
                 "browser.login_for",
                 request,
                 voice,
                 TwoEngines.call_opts(ctx.e)
               )

      assert message == "A sign-in is approved in the chat, not by voice."
      assert ctx.e |> journal() |> Enum.map(& &1.refusal) == ["unavailable", "not_attended"]
      assert drain_chrome([]) == []
    end

    test "the owner's granted tab: only on their turn, and only its narrower set of actions",
         ctx do
      request = %{
        "action" => "snapshot",
        "args" => %{},
        "profile" => "selected_tab",
        "conversation" => "owner-YWxsb3RtZW50"
      }

      background = %{
        session_id: ctx.sid,
        computer_use_origin: :background,
        source_trust: :operator
      }

      assert {:error, %Outcome{status: :refused, refusal: :not_attended}} =
               Computers.call(
                 TwoEngines.computer(ctx.e),
                 BrowserCapability,
                 "browser.snapshot",
                 request,
                 background,
                 TwoEngines.call_opts(ctx.e)
               )

      # Refused on the server first, for a turn the owner is not in.
      assert {:ok, %{success: false, error: refused}} =
               call(
                 ctx,
                 on_mac(%{"action" => "snapshot", "profile" => "selected_tab"}),
                 %{computer_use_origin: :background}
               )

      assert refused =~ "attached_tab_not_allowed"

      # On the owner's turn, the tab cannot open another: the computer's own
      # profile refuses it before its browser is asked.
      assert {:ok, %{success: false, error: error}} =
               in_turn(fn ->
                 call(
                   ctx,
                   on_mac(%{
                     "action" => "open",
                     "url" => "https://allotment.example.com",
                     "profile" => "selected_tab"
                   })
                 )
               end)

      assert error =~ "On studio Mac: "
      assert error =~ "unsupported_in_attached_tab"
      refute_received {:chrome, :open, _args, _affinity, _caller}
    end

    test "the computer's browser switched off there: refused there, then by the server", ctx do
      e = ctx.e
      Agent.update(e.switch_agent, &Keyword.put(&1, :browser, false))

      assert {:ok, %{success: false, error: error}} =
               in_turn(fn -> call(ctx, on_mac(%{"action" => "tabs"})) end)

      assert error =~ "studio Mac has the browser switched off"
      assert exec_event().refusal == :off
      assert [%{status: "refused", refusal: "off"}] = journal(e)

      :ok = Offers.changed(e.offers)
      await_offer(e, "browser", :off)

      assert {:ok, %{success: false, error: again}} = call(ctx, on_mac(%{"action" => "tabs"}))
      assert again =~ "studio Mac has the browser switched off"
      assert exec_event().computer_refusal == "not_offered"
      assert length(journal(e)) == 1
      assert drain_chrome([]) == []
    end

    test "a computer that is away is refused at once, and nothing is sent", ctx do
      ExUnit.CaptureLog.capture_log(fn -> :ok = TwoEngines.drop_session!(ctx.e) end)
      await_away(ctx.e)

      assert {:ok, %{success: false, error: error}} = call(ctx, on_mac(%{"action" => "tabs"}))
      assert error =~ "studio Mac is asleep or offline (last seen "
      assert exec_event().computer_refusal == "away"
      assert journal(ctx.e) == []
    end
  end

  describe "a task's browser stays on one machine" do
    test "a call that names no computer carries on in the computer's browser, and never here",
         ctx do
      test = self()

      turn =
        Task.async(fn ->
          opened =
            call(ctx, on_mac(%{"action" => "open", "url" => "https://allotment.example.com"}))

          # `status` never starts a browser here, so a call that wrongly ran
          # on this server could not launch one.
          looked = call(ctx, %{"action" => "status"})
          carried = Choice.resolve(browser_capability(), %{}, turn(ctx))
          send(test, :looked)

          receive do
            :go -> :ok
          after
            20_000 -> flunk("the test never let the turn go on")
          end

          {opened, looked, carried, call(ctx, %{"action" => "status"})}
        end)

      assert_receive :looked, 10_000

      # Another turn, with no browser of its own on a computer, runs here.
      assert {:ok, _args, %{computer: :here}} =
               Task.await(
                 Task.async(fn -> Choice.resolve(browser_capability(), %{}, turn(ctx)) end)
               )

      ExUnit.CaptureLog.capture_log(fn -> :ok = TwoEngines.drop_session!(ctx.e) end)
      await_away(ctx.e)
      send(turn.pid, :go)

      {opened, looked, carried, after_away} = Task.await(turn, 30_000)
      assert decoded(opened)["computer"] == "studio Mac"
      assert decoded(looked)["computer"] == "studio Mac"
      assert {:ok, _args, %{computer: %Computer{name: "studio Mac"}}} = carried

      # The computer went away mid-task: the task fails there, never moving to
      # this server's own browser.
      assert {:ok, %{success: false, error: error}} = after_away
      assert error =~ "studio Mac is asleep or offline"
      assert ops(ctx.e) == ~w(browser.open browser.status)
    end
  end

  # -- helpers -------------------------------------------------------------------------

  defp browser_capability, do: Builtin.from_tool_module(BrowserTool)

  defp assert_server_copy(ctx, path, under, bytes) do
    assert String.starts_with?(path, Path.join([ctx.server, "browser" | under]) <> "/")
    assert File.read!(path) == bytes
    refute String.starts_with?(path, ctx.computer_dir)
  end

  defp drain_chrome(seen) do
    receive do
      {:chrome, op, args, affinity, caller} -> drain_chrome([{op, args, affinity, caller} | seen])
    after
      0 -> Enum.reverse(seen)
    end
  end

  defp request_types(ctx) do
    ctx.browser.connection |> FakeBrowserHostConnection.requests() |> Enum.map(&elem(&1, 0))
  end

  defp await_release(ctx, attempts \\ 1_000) do
    cond do
      FakeBrowserHostConnection.releases(ctx.browser.connection) != [] ->
        :ok

      attempts == 0 ->
        flunk("the computer never ended the turn's pane task")

      true ->
        # sleep: polls the fake app, which tells nobody of a release
        Process.sleep(10)
        await_release(ctx, attempts - 1)
    end
  end

  # Every turn the computer held has ended there (`Browser.HeldTurn`).
  defp await_no_held_turns(ctx, attempts \\ 1_000) do
    held = Elixir.Registry.count(ctx.browser.seams.turns.registry)

    cond do
      held == 0 ->
        :ok

      attempts == 0 ->
        flunk("the computer never heard the turn ended")

      true ->
        # sleep: polls the computer's held turns, which tell nobody they ended
        Process.sleep(10)
        await_no_held_turns(ctx, attempts - 1)
    end
  end

  defp await_offer(e, id, state, attempts \\ 1_000) do
    offers = FermixCore.Computers.Registry.live(e.registry)[e.device_id][:offers] || []

    cond do
      Enum.any?(offers, &(&1.id == id and &1.state == state)) ->
        :ok

      attempts == 0 ->
        flunk("the server never heard #{id} is #{state}")

      true ->
        # sleep: polls the server's live view, which tells only the Always On watch
        Process.sleep(10)
        await_offer(e, id, state, attempts - 1)
    end
  end

  defp await_away(e, attempts \\ 1_000) do
    cond do
      FermixCore.Computers.Registry.live(e.registry)[e.device_id] == nil ->
        :ok

      attempts == 0 ->
        flunk("the server never saw the computer go")

      true ->
        # sleep: polls the server's live view, which tells only the Always On watch
        Process.sleep(10)
        await_away(e, attempts - 1)
    end
  end

  # The fake app: a login page, the login saved for it, and the fill.
  defp app_answers do
    %{
      "tab.open" =>
        {:ok,
         %{
           "tab_id" => "t1",
           "url" => "https://example.com/login",
           "title" => "Sign in",
           "page" => login_page()
         }},
      "page.login_for" =>
        {:ok, %{"login_site" => "example.com", "username" => "person@example.com"}},
      "page.sign_in" => fn payload ->
        filled = Enum.filter(["username", "password"], &Map.has_key?(payload, &1 <> "_ref"))

        {:ok,
         %{
           "url" => "https://example.com/login",
           "title" => "Sign in",
           "filled" => filled,
           "page" => login_page()
         }}
      end,
      "tab.focus" =>
        {:ok, %{"tab_id" => "t1", "url" => "https://example.com/login", "title" => "Sign in"}},
      "tab.list" =>
        {:ok,
         %{
           "tabs" => [
             %{"tab_id" => "t1", "url" => "https://example.com/login", "title" => "Sign in"}
           ]
         }}
    }
  end

  defp login_page do
    %{
      "url" => "https://example.com/login",
      "title" => "Sign in",
      "ready_state" => "complete",
      "nodes" => [
        %{
          "nodeId" => "1",
          "role" => %{"value" => "RootWebArea"},
          "name" => %{"value" => "Sign in"},
          "childIds" => ["2", "3", "4"]
        },
        %{
          "nodeId" => "2",
          "backendDOMNodeId" => 11,
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Email"}
        },
        %{
          "nodeId" => "3",
          "backendDOMNodeId" => 12,
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Password"}
        },
        %{
          "nodeId" => "4",
          "backendDOMNodeId" => 13,
          "role" => %{"value" => "button"},
          "name" => %{"value" => "Sign in"}
        }
      ]
    }
  end
end
