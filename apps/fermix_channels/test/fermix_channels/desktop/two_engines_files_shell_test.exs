defmodule FermixChannels.Desktop.TwoEnginesFilesShellTest do
  # M97 §6.4, §6.5: a server's tool call names its computer and runs there,
  # over the real link, through the same tool code the server runs, under the
  # computer's own sandbox: `strict` with its workspace under the computer's
  # temporary home, while the server's (the test VM's application
  # environment) is `standard` and never names that home. Every call is
  # driven through `Capability.execute/3`, the agent loop's own boundary, and
  # is exactly one exec event on the server. async: false: the relay's dial
  # names are VM-wide (`TwoEngines`).
  use ExUnit.Case, async: false

  alias FermixChannels.Desktop.Offers
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Test.TwoEngines
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Computers.Journal
  alias FermixCore.Computers.Registry
  alias FermixCore.Sandbox.Config
  alias FermixCore.Tools.ContentSearch
  alias FermixCore.Tools.FileEdit
  alias FermixCore.Tools.FileRead
  alias FermixCore.Tools.FileWrite
  alias FermixCore.Tools.GitRead
  alias FermixCore.Tools.GitWrite
  alias FermixCore.Tools.GlobSearch
  alias FermixCore.Tools.SendAttachment
  alias FermixCore.Tools.Shell
  alias FermixCore.Tools.ViewImage
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>

  setup context do
    sid = "two-engines-tools-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: sid)

    sends =
      if context[:drop_first_answer],
        do: [send: drop_first_answer(self(), :counters.new(1, []))],
        else: []

    engines = TwoEngines.start!([switches: [:files_and_shell]] ++ sends)
    workspace = engines.sandbox.workspace_root
    assert engines.sandbox.mode == :strict
    refute Config.current().mode == :strict

    # The server's own workspace, where a file sent from the computer lands.
    server = SafeRm.make_tmp_dir!("two_engines_server_workspace")
    on_exit(fn -> SafeRm.rm_rf!(server) end)
    File.mkdir_p!(Path.join(server, "workspace"))

    %{e: engines, ws: workspace, sid: sid, server: server}
  end

  # An owner's chat turn on the server, its sandbox its own and the home's one
  # computer the one these engines run.
  defp turn(ctx, more \\ %{}) do
    test = self()

    Map.merge(
      %{
        source_trust: :operator,
        computer_use_origin: :interactive,
        session_id: ctx.sid,
        agent_name: "main",
        conversation_key: {"telegram", ctx.sid, :root},
        chat_type: "private",
        outside_sources: MapSet.new(),
        computers: [TwoEngines.computer(ctx.e)],
        computer_call_opts: TwoEngines.call_opts(ctx.e),
        sandbox_config:
          Config.normalize(
            mode: :strict,
            home: ctx.server,
            os_home: ctx.server,
            workspace_root: Path.join(ctx.server, "workspace")
          ),
        reply_fn: fn part ->
          send(test, {:reply, part})
          :ok
        end
      },
      more
    )
  end

  defp call(ctx, tool, args, more \\ %{}) do
    Builtin.from_tool_module(tool)
    |> Capability.execute(Map.put(args, "computer", "studio Mac"), turn(ctx, more))
  end

  # The call's one exec event on the server.
  defp exec_event(tool) do
    assert_receive {:telemetry, [:fermix, :tool, :exec], _measure, %{tool: ^tool} = metadata},
                   10_000

    refute_received {:telemetry, [:fermix, :tool, :exec], _measure, _another}
    metadata
  end

  defp journal(e) do
    {:ok, %{entries: entries}} = Journal.list(Journal.dir(e.root))
    entries
  end

  describe "each operation runs on the computer, under its sandbox" do
    test "file_read reads the computer's file and names the computer", %{e: e, ws: ws} = ctx do
      File.write!(Path.join(ws, "seeds.txt"), "tomatoes, beans")

      assert {:ok, %{success: true, output: output}} =
               call(ctx, FileRead, %{"path" => Path.join(ws, "seeds.txt")})

      assert output == "On studio Mac:\ntomatoes, beans"

      metadata = exec_event("file_read")
      assert metadata.success
      assert metadata.computer == e.device_id
      assert metadata.invoke_status == :ok
      assert [%{op: "file.read", capability: "files", status: "ok", id: id}] = journal(e)
      assert metadata.invocation == id

      # The server's own sandbox has no root there.
      assert {:ok, %{success: false}} =
               FileRead.execute(%{"path" => Path.join(ws, "seeds.txt")}, turn(ctx))
    end

    test "file_write, file_edit, glob_search and content_search", %{e: e, ws: ws} = ctx do
      path = Path.join(ws, "plan.md")

      assert {:ok, %{success: true}} =
               call(ctx, FileWrite, %{"path" => path, "content" => "# Plan\nbuy seeds"})

      assert exec_event("file_write").invoke_status == :ok

      assert {:ok, %{success: true}} =
               call(ctx, FileEdit, %{"path" => path, "old_string" => "buy", "new_string" => "sow"})

      assert exec_event("file_edit").invoke_status == :ok
      assert File.read!(path) == "# Plan\nsow seeds"

      assert {:ok, %{success: true, output: "On studio Mac:\n" <> globbed}} =
               call(ctx, GlobSearch, %{"path" => ws, "pattern" => "*.md"})

      assert exec_event("glob_search").invoke_status == :ok
      assert [found] = Jason.decode!(globbed)
      assert String.ends_with?(found, "plan.md")

      assert {:ok, %{success: true, output: "On studio Mac:\n" <> searched}} =
               call(ctx, ContentSearch, %{"path" => ws, "pattern" => "sow"})

      assert exec_event("content_search").invoke_status == :ok
      assert %{"matches" => [%{"line" => 2}]} = Jason.decode!(searched)

      assert e |> journal() |> Enum.map(& &1.op) ==
               ["file.search", "file.glob", "file.edit", "file.write"]
    end

    test "git_read and git_write run git there", %{ws: ws} = ctx do
      repo = Path.join(ws, "garden")
      File.mkdir_p!(repo)
      {_out, 0} = System.cmd("git", ["init", "-q", repo])
      File.write!(Path.join(repo, "beds.txt"), "north bed")

      assert {:ok, %{success: true}} =
               call(ctx, GitWrite, %{"repo" => repo, "command" => "add", "args" => ["beds.txt"]})

      assert exec_event("git_write").invoke_status == :ok

      assert {:ok, %{success: true, output: output}} =
               call(ctx, GitRead, %{"repo" => repo, "command" => "status", "args" => ["--short"]})

      assert output == "On studio Mac:\nA  beds.txt\n"
      assert exec_event("git_read").invoke_status == :ok
    end

    test "shell runs a command there, and output above 256 KiB rides the part", %{ws: ws} = ctx do
      assert {:ok, %{success: true, output: "On studio Mac:\n" <> where}} =
               call(ctx, Shell, %{"command" => "pwd", "working_dir" => ws})

      assert String.trim(where) =~ "workspace"
      assert exec_event("shell").invoke_status == :ok

      command = "head -c 300000 /dev/zero | tr '\\0' a"

      assert {:ok, %{success: true, output: "On studio Mac:\n" <> big}} =
               call(ctx, Shell, %{"command" => command, "working_dir" => ws})

      assert big == :binary.copy("a", 300_000)
      assert exec_event("shell").success
    end

    test "view_image brings a picture above 256 KiB back whole", %{ws: ws} = ctx do
      picture = @png <> :crypto.strong_rand_bytes(300 * 1_024)
      File.write!(Path.join(ws, "leaf.png"), picture)

      assert {:ok, %{success: true, output: "On studio Mac:\n" <> summary, images: [image]}} =
               call(ctx, ViewImage, %{"paths" => [Path.join(ws, "leaf.png")]})

      assert summary =~ "leaf.png"
      assert image == %{type: :image, mime_type: "image/png", data: picture}
      assert exec_event("view_image").invoke_status == :ok
    end

    test "send_attachment brings a large file to this server and sends it once",
         %{e: e, ws: ws} = ctx do
      bytes = :crypto.strong_rand_bytes(300 * 1_024)
      File.write!(Path.join(ws, "harvest.pdf"), bytes)

      assert {:ok, %{success: true, output: "Sent attachment from studio Mac: harvest.pdf"}} =
               call(ctx, SendAttachment, %{"path" => Path.join(ws, "harvest.pdf")})

      assert_received {:reply, {:media, %{kind: :document, filename: "harvest.pdf", path: path}}}
      refute_received {:reply, {:media, _again}}
      assert String.ends_with?(path, "-harvest.pdf")
      assert path =~ Path.join([Path.basename(ctx.server), "workspace", "media", "computers"])
      assert File.read!(path) == bytes
      assert exec_event("send_attachment").invoke_status == :ok
      assert [%{op: "file.send", status: "ok"}] = journal(e)
    end

    test "content above 256 KiB goes up as the request's part", %{ws: ws} = ctx do
      content = :binary.copy("row\n", 80 * 1_024)
      path = Path.join(ws, "log.csv")

      assert {:ok, %{success: true}} =
               call(ctx, FileWrite, %{"path" => path, "content" => content})

      assert File.read!(path) == content
    end
  end

  describe "the computer's sandbox and its protected paths" do
    test "a path outside its roots is refused there, and allowed only there", %{e: e} = ctx do
      outside = Path.join(e.root, "private/notes.txt")

      assert {:ok, %{success: false, error: error}} =
               call(ctx, FileWrite, %{"path" => outside, "content" => "x"})

      assert error =~ "On studio Mac: "
      assert error =~ "notes.txt is outside this computer's sandbox."

      assert error =~
               "Someone at studio Mac can allow the folder; it cannot be allowed from here."

      refute File.exists?(outside)

      metadata = exec_event("file_write")
      assert metadata.invoke_status == :refused
      assert metadata.refusal == :outside_sandbox
    end

    test "asking for a folder on a computer is refused: it is allowed at that computer", ctx do
      assert {:ok, %{success: false, error: error}} =
               call(ctx, FermixCore.Tools.RequestDirectoryAccess, %{
                 "path" => "/Users/pat/Taxes",
                 "reason" => "the receipts are there"
               })

      assert error =~ "Folders on studio Mac are allowed only at studio Mac"
      assert journal(ctx.e) == []
    end

    test "its own settings, secrets and keys stay refused", %{e: e} = ctx do
      File.write!(
        Path.join(e.root, "machine.toml"),
        "[fermix_core.computer]\nfiles_and_shell = true\n"
      )

      for path <- ["machine.toml", "config.toml", "device/desktop.json", "secrets/token"] do
        assert {:ok, %{success: false, error: error}} =
                 call(ctx, FileRead, %{"path" => Path.join(e.root, path)})

        assert error =~ "Path is protected by the sandbox", path
        assert exec_event("file_read").invoke_status == :failed
      end

      assert e |> journal() |> Enum.map(& &1.status) == List.duplicate("failed", 4)
    end
  end

  describe "a tool that ran and failed" do
    # The computer's journal and the server's exec event tell it from a
    # success; the model still reads the tool's whole error.
    test "a failing command is failed in the journal and the exec event, its output whole",
         %{e: e, ws: ws} = ctx do
      assert {:ok, %{success: false, error: error}} =
               call(ctx, Shell, %{"command" => "echo almost; exit 3", "working_dir" => ws})

      assert error == "On studio Mac: Command failed (exit code 3):\nalmost\n"

      metadata = exec_event("shell")
      refute metadata.success
      assert metadata.invoke_status == :failed
      assert metadata.error_summary =~ "Command failed (exit code 3)"
      assert [%{op: "shell.run", status: "failed", id: id}] = journal(e)
      assert metadata.invocation == id
    end

    test "a failing command's output above 256 KiB still rides the part", %{ws: ws} = ctx do
      command = "head -c 300000 /dev/zero | tr '\\0' c; exit 2"

      assert {:ok, %{success: false, error: "On studio Mac: " <> error}} =
               call(ctx, Shell, %{"command" => command, "working_dir" => ws})

      assert error == "Command failed (exit code 2):\n" <> :binary.copy("c", 300_000)
      assert exec_event("shell").invoke_status == :failed
    end
  end

  describe "a lost answer" do
    test "a command whose answer is lost is not known, and is never run again",
         %{e: e, ws: ws} = ctx do
      command = "echo ran >> ran.txt; while [ ! -e go ]; do sleep 0.05; done"
      task = Task.async(fn -> call(ctx, Shell, %{"command" => command, "working_dir" => ws}) end)
      await_file(Path.join(ws, "ran.txt"))

      ExUnit.CaptureLog.capture_log(fn ->
        crash_admission!(e)
        :ok = TwoEngines.drop_session!(e)
        :ok = TwoEngines.reconnect!(e)
      end)

      assert {:ok, %{success: false, error: error}} = Task.await(task, 20_000)

      assert error ==
               "Fermix lost studio Mac's answer, so whether echo ran happened is not known. " <>
                 "Check before doing it again."

      File.write!(Path.join(ws, "go"), "")
      assert File.read!(Path.join(ws, "ran.txt")) == "ran\n"
      assert [%{op: "shell.run", status: "unknown"}] = journal(e)
      assert exec_event("shell").invoke_status == :unknown
    end

    @tag :drop_first_answer
    test "a read whose answer is lost is read again once, under a new id",
         %{e: e, ws: ws} = ctx do
      File.write!(Path.join(ws, "seeds.txt"), "squash")
      task = Task.async(fn -> call(ctx, FileRead, %{"path" => Path.join(ws, "seeds.txt")}) end)
      assert_receive {:dropped_answer, first}, 10_000

      ExUnit.CaptureLog.capture_log(fn ->
        crash_admission!(e, "ok")
        :ok = TwoEngines.drop_session!(e)
        :ok = TwoEngines.reconnect!(e)
      end)

      assert {:ok, %{success: true, output: "On studio Mac:\nsquash"}} = Task.await(task, 20_000)
      assert [%{status: "ok", id: second}, %{status: "ok", id: ^first}] = journal(e)
      refute second == first
      assert exec_event("file_read").invocation == second
    end
  end

  describe "the computer's own switch" do
    # M97 D27: one switch decides files and commands; off, the server hears
    # both off.
    test "off, and the server knows it: nothing is sent", %{e: e} = ctx do
      Agent.update(e.switch_agent, &Keyword.put(&1, :files_and_shell, false))
      :ok = Offers.changed(e.offers)
      await_offer(e, "files", :off)
      await_offer(e, "shell", :off)

      assert {:ok, %{success: false, error: error}} =
               call(ctx, FileRead, %{"path" => "notes.txt"})

      assert error ==
               "studio Mac has files switched off. Only someone at studio Mac can switch it on."

      assert exec_event("file_read").computer_refusal == "not_offered"
      assert journal(e) == []
    end

    test "off before the server heard: the computer refuses it", %{e: e, ws: ws} = ctx do
      Agent.update(e.switch_agent, &Keyword.put(&1, :files_and_shell, false))

      assert {:ok, %{success: false, error: error}} =
               call(ctx, FileRead, %{"path" => Path.join(ws, "notes.txt")})

      assert error =~ "studio Mac has files switched off"
      assert exec_event("file_read").refusal == :off
      assert [%{status: "refused", refusal: "off"}] = journal(e)
    end
  end

  test "a computer that is away is refused at once, and nothing is sent", %{e: e} = ctx do
    ExUnit.CaptureLog.capture_log(fn -> :ok = TwoEngines.drop_session!(e) end)
    await_away(e)

    assert {:ok, %{success: false, error: error}} = call(ctx, FileRead, %{"path" => "notes.txt"})

    assert error =~ "studio Mac is asleep or offline (last seen "
    assert error =~ "Nothing waits for it to wake."
    assert exec_event("file_read").computer_refusal == "away"
    assert journal(e) == []
  end

  # -- helpers -------------------------------------------------------------------

  # Admission dies under a run, as a crash would; the restarted one journals
  # what ran unfinished as unknown, and holds no answer it sent before.
  defp crash_admission!(e, journaled \\ "unknown") do
    admission = Process.whereis(e.admission)
    ref = Process.monitor(admission)
    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^ref, :process, ^admission, :killed}
    await_journaled(e.root, journaled)
  end

  defp await_journaled(root, status, attempts \\ 1_000) do
    case Journal.list(Journal.dir(root)) do
      {:ok, %{entries: [%{status: ^status} | _older]}} ->
        :ok

      _not_yet when attempts == 0 ->
        flunk("the computer never journaled #{status}")

      _not_yet ->
        # sleep: polls the computer's journal, which announces nothing
        Process.sleep(10)
        await_journaled(root, status, attempts - 1)
    end
  end

  defp await_file(path, attempts \\ 1_000) do
    cond do
      File.exists?(path) ->
        :ok

      attempts == 0 ->
        flunk("the command never started")

      true ->
        # sleep: polls the file the command writes as it starts, which tells nobody
        Process.sleep(10)
        await_file(path, attempts - 1)
    end
  end

  defp await_offer(e, id, state, attempts \\ 1_000) do
    offers = Registry.live(e.registry)[e.device_id][:offers] || []

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
      Registry.live(e.registry)[e.device_id] == nil ->
        :ok

      attempts == 0 ->
        flunk("the server never saw the computer go")

      true ->
        # sleep: polls the server's live view, which tells only the Always On watch
        Process.sleep(10)
        await_away(e, attempts - 1)
    end
  end

  # The computer's answers reach the link, but the first `invoke_result`,
  # which is dropped and told to the test that started the engines. It holds
  # across Admission's restart, which starts with the same options.
  defp drop_first_answer(test, counter) do
    fn relay, event, payload ->
      if event["t"] == "invoke_result" and :counters.get(counter, 1) == 0 do
        :counters.add(counter, 1, 1)
        send(test, {:dropped_answer, event["id"]})
        :ok
      else
        Relay.send_event(relay, event, payload)
      end
    end
  end
end
