defmodule FermixCore.Harness.SignInTest do
  # M98 D10 (G1b): an agent's sign-in state on this machine, its mark in the
  # coding store, and the sentences that name it. The store is a per-test file;
  # the sign-in file's stat and the clock are injected, never read off a real
  # clock.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Harness.MachineStore
  alias FermixCore.Harness.SignIn
  alias FermixTestSupport.SafeRm

  @now ~U[2026-03-14 09:26:53Z]
  @first %{"size" => 412, "mtime" => 1_773_480_413, "inode" => 90_211}
  @second %{"size" => 418, "mtime" => 1_773_481_002, "inode" => 90_377}

  setup do
    home = SafeRm.make_tmp_dir!("harness-sign-in")
    on_exit(fn -> SafeRm.rm_rf!(home) end)

    codex_home = Path.join(home, "codex-home")
    claude_dir = Path.join(home, "claude-dir")
    File.mkdir!(codex_home)
    File.mkdir!(claude_dir)
    path = MachineStore.path(home)
    store = start_supervised!({MachineStore, name: nil, path: path, open?: true})

    %{
      home: home,
      path: path,
      store: store,
      codex_auth: Path.join(codex_home, "auth.json"),
      opts: [
        store: store,
        path: path,
        vendor_opts: [codex_home: codex_home, claude_config_dir: claude_dir],
        stat: fn _file -> {:ok, @first} end,
        now: fn -> @now end
      ]
    }
  end

  defp signed_out_row(vendor, run_id \\ "hr_0a1b2c3d4e5f"),
    do: %{id: run_id, vendor: vendor, status: "failed", reason: "signed_out"}

  describe "view/2" do
    test "a mark reads signed out wherever the agent has a sign-in" do
      assert SignIn.view(:authenticated, %{run_id: "hr_0a1b2c3d4e5f"}) == :signed_out
      assert SignIn.view(:unverified, %{run_id: "hr_0a1b2c3d4e5f"}) == :signed_out
    end

    test "with no mark, the file reads as it is found" do
      assert SignIn.view(:authenticated, nil) == :sign_in_found
      assert SignIn.view(:unverified, nil) == :not_verified
      assert SignIn.view(:absent, nil) == :not_signed_in
    end

    test "no sign-in at all is not signed in, mark or not" do
      assert SignIn.view(:absent, %{run_id: "hr_0a1b2c3d4e5f"}) == :not_signed_in
    end

    test "each state has the owner's word" do
      assert SignIn.word(:sign_in_found) == "sign-in found"
      assert SignIn.word(:not_verified) == "sign-in not verified"
      assert SignIn.word(:not_signed_in) == "not signed in"
      assert SignIn.word(:signed_out) == "signed out (a run failed to sign in)"
    end
  end

  describe "the sentences" do
    test "a run that failed to sign in names the agent and the machine, and says it stopped" do
      assert SignIn.sentence("codex", "this Mac") ==
               "Codex is signed out on this Mac, so the run stopped. Sign in to Codex on " <>
                 "this Mac (run codex login in a terminal), then tell me."

      assert SignIn.sentence("claude", "this server") ==
               "Claude Code is signed out on this server, so the run stopped. Sign in to " <>
                 "Claude Code on this server (run claude in a terminal), then tell me."

      for sentence <- SignIn.sentences(), do: refute(sentence =~ "did nothing")
    end

    test "a mark says what clears it" do
      assert SignIn.marked_sentence("codex", "this Mac") ==
               "Codex failed to sign in on its last run on this Mac. Sign in again (run " <>
                 "codex login in a terminal); the next run that works clears this."
    end

    test "the machine is this Mac, this server or this computer" do
      assert SignIn.machine_word(macos?: true, server?: false) == "this Mac"
      assert SignIn.machine_word(macos?: false, server?: true) == "this server"
      assert SignIn.machine_word(macos?: false, server?: false) == "this computer"
      assert SignIn.machine_word(machine: "this Mac", macos?: false) == "this Mac"
    end

    test "a run's note is the sentence for a signed-out run and nothing otherwise" do
      opts = [machine: "this computer"]

      assert SignIn.run_note(signed_out_row("claude"), opts) ==
               SignIn.sentence("claude", "this computer")

      assert SignIn.run_note(%{signed_out_row("codex") | reason: "exit_1"}, opts) == ""
      assert SignIn.run_note(%{signed_out_row("codex_cloud") | reason: "cloud_auth"}, opts) == ""
    end
  end

  describe "a run's outcome" do
    test "a run that failed to sign in marks its agent with its sign-in file's stat", ctx do
      File.write!(ctx.codex_auth, ~s({"auth_mode":"apikey","OPENAI_API_KEY":"sk-invented"}))

      assert :ok = SignIn.record_outcome(signed_out_row("codex"), ctx.opts)

      assert {:ok, %{"codex" => mark}} = MachineStore.marks(server: ctx.store)
      assert mark.run_id == "hr_0a1b2c3d4e5f"
      assert mark.marked_at == "2026-03-14T09:26:53Z"
      assert mark.sign_in_file == ctx.codex_auth
      assert mark.file_stat == @first
      refute inspect(mark) =~ "sk-invented"
    end

    test "an agent with no sign-in file is marked with none", ctx do
      assert :ok = SignIn.record_outcome(signed_out_row("claude"), ctx.opts)

      assert {:ok, %{"claude" => %{sign_in_file: nil, file_stat: nil}}} =
               MachineStore.marks(server: ctx.store)
    end

    test "a run that completes clears its agent's mark; other outcomes leave it", ctx do
      :ok = SignIn.record_outcome(signed_out_row("claude"), ctx.opts)

      for status <- ~w(failed cancelled interrupted blocked) do
        row = %{signed_out_row("claude") | status: status, reason: "exit_1"}
        :ok = SignIn.record_outcome(row, ctx.opts)
      end

      assert {:ok, %{"claude" => _kept}} = MachineStore.marks(server: ctx.store)

      completed = %{signed_out_row("claude") | status: "completed", reason: nil}
      assert :ok = SignIn.record_outcome(completed, ctx.opts)
      assert MachineStore.marks(server: ctx.store) == {:ok, %{}}
    end

    test "a cloud run touches no mark", ctx do
      row = %{signed_out_row("codex_cloud") | status: "completed", reason: nil}
      assert :ok = SignIn.record_outcome(row, ctx.opts)
      assert MachineStore.marks(server: ctx.store) == {:ok, %{}}
    end

    test "a store that cannot keep the mark is logged, never raised", ctx do
      absent =
        start_supervised!({MachineStore, name: nil, path: ctx.path, open?: false}, id: :absent)

      opts = Keyword.put(ctx.opts, :store, absent)

      log =
        capture_log(fn ->
          assert :ok = SignIn.record_outcome(signed_out_row("codex"), opts)
        end)

      assert log =~ "no_coding_agent"
    end
  end

  describe "a check" do
    setup ctx do
      File.write!(ctx.codex_auth, "{}")
      :ok = SignIn.record_outcome(signed_out_row("codex"), ctx.opts)
      :ok = SignIn.record_outcome(signed_out_row("claude", "hr_1234abcd5678"), ctx.opts)
      :ok
    end

    test "keeps a mark whose sign-in file is as it was, and one with no file", ctx do
      assert :ok = SignIn.check_all(ctx.opts)
      assert {:ok, marks} = MachineStore.marks(server: ctx.store)
      assert Map.keys(marks) |> Enum.sort() == ["claude", "codex"]
      assert {:ok, read} = SignIn.marks(ctx.opts)
      assert Map.keys(read) |> Enum.sort() == ["claude", "codex"]
    end

    test "clears a mark whose sign-in file changed", ctx do
      changed = Keyword.put(ctx.opts, :stat, fn _file -> {:ok, @second} end)

      assert {:ok, read} = SignIn.marks(changed)
      assert Map.keys(read) == ["claude"]

      assert :ok = SignIn.check_all(changed)
      assert {:ok, marks} = MachineStore.marks(server: ctx.store)
      assert Map.keys(marks) == ["claude"]
    end

    test "clears a mark whose sign-in file vanished, or appeared where there was none", ctx do
      SafeRm.rm!(ctx.codex_auth)
      claude_file = Path.join(ctx.opts[:vendor_opts][:claude_config_dir], ".credentials.json")
      File.write!(claude_file, "{}")

      assert {:ok, %{}} = SignIn.marks(ctx.opts)
      assert :ok = SignIn.check_all(ctx.opts)
      assert MachineStore.marks(server: ctx.store) == {:ok, %{}}
    end

    test "the owner's word clears the marks it names", ctx do
      assert :ok = SignIn.clear(["claude"], ctx.opts)
      assert {:ok, marks} = MachineStore.marks(server: ctx.store)
      assert Map.keys(marks) == ["codex"]
    end
  end

  describe "reading the marks where no agent can run" do
    test "a machine with no store has no mark", ctx do
      opts = Keyword.put(ctx.opts, :path, MachineStore.path(Path.join(ctx.home, "elsewhere")))
      assert SignIn.marks(opts) == {:ok, %{}}
    end
  end
end
