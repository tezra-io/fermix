defmodule FermixCore.Management.DetectTest do
  use ExUnit.Case, async: true

  alias FermixCore.Harness.MachineStore
  alias FermixCore.Management.Detect

  defp probes do
    [
      existing_primary: fn -> {:ok, :openai_codex} end,
      claude_code: fn -> true end,
      codex_cli: fn -> false end,
      ollama: fn -> {:error, :econnrefused} end,
      harness_vendors: fn -> vendors(true) end,
      sign_in_marks: fn -> {:ok, %{}} end,
      machine: fn -> "this computer" end,
      engine_role: fn -> :primary end
    ] ++ meetbot_probes(true, true, true)
  end

  defp meetbot_probes(installed?, browser?, signed_in?) do
    [
      meetbot_installed: fn -> installed? end,
      meetbot_browser_installed: fn -> browser? end,
      meetbot_signed_in: fn -> signed_in? end,
      meet_here: fn -> :ok end
    ]
  end

  test "answers one row per target, in the order asked" do
    targets = ~w(harness_vendors existing_primary claude_code)

    assert %{"results" => results} = Detect.run(targets, probes: probes())
    assert Enum.map(results, & &1["target"]) == targets

    assert results == [
             %{
               "target" => "harness_vendors",
               "present" => true,
               "detail" => "claude, codex",
               "vendors" => vendor_rows(),
               "guidance" => nil
             },
             %{"target" => "existing_primary", "present" => true, "detail" => "openai_codex"},
             %{"target" => "claude_code", "present" => true, "detail" => nil}
           ]
  end

  test "every row carries the three published fields, present or not" do
    assert %{"results" => results} = Detect.run(Detect.targets(), probes: probes())

    for row <- results do
      # The per-target extras beside the three fields every row carries: the
      # harness row's vendors and guidance, the notetaker row's sign-in and
      # whether Google Meet can run here.
      extras = ~w(vendors guidance signed_in available)
      assert row |> Map.drop(extras) |> Map.keys() |> Enum.sort() == ~w(detail present target)

      assert is_boolean(row["present"])
      assert is_nil(row["detail"]) or is_binary(row["detail"])
      assert Map.has_key?(row, "available") == (row["target"] == "meetbot")
    end
  end

  # A home that has never chosen a provider is what tells onboarding to ask.
  test "a home with no chosen primary reports the target absent" do
    probes = Keyword.put(probes(), :existing_primary, fn -> {:ok, nil} end)

    assert %{"results" => [row]} = Detect.run(["existing_primary"], probes: probes)
    assert row == %{"target" => "existing_primary", "present" => false, "detail" => nil}
  end

  # Two blocks flagged primary is a configuration that exists and is ambiguous.
  # Reporting it absent would send onboarding through a first-run flow over a
  # home that already has providers configured.
  test "an ambiguous primary is present with no single name" do
    probes = Keyword.put(probes(), :existing_primary, fn -> {:error, :multiple_primary} end)

    assert %{"results" => [row]} = Detect.run(["existing_primary"], probes: probes)
    assert row == %{"target" => "existing_primary", "present" => true, "detail" => nil}
  end

  test "a reachable Ollama reports how many models it serves" do
    probes = Keyword.put(probes(), :ollama, fn -> {:ok, [%{id: "a"}, %{id: "b"}]} end)

    assert %{"results" => [row]} = Detect.run(["ollama"], probes: probes)
    assert row == %{"target" => "ollama", "present" => true, "detail" => "2 models"}

    single = Keyword.put(probes(), :ollama, fn -> {:ok, [%{id: "a"}]} end)
    assert %{"results" => [one]} = Detect.run(["ollama"], probes: single)
    assert one["detail"] == "1 model"
  end

  test "no installed harness vendor is absent rather than an empty name list" do
    probes = Keyword.put(probes(), :harness_vendors, fn -> vendors(false) end)

    assert %{"results" => [row]} = Detect.run(["harness_vendors"], probes: probes)
    refute row["present"]
    assert row["detail"] == nil
    assert length(row["vendors"]) == 2
    assert is_binary(row["guidance"])
  end

  test "harness readiness publishes installed, version and auth facts without paths" do
    detections = %{
      "claude" => %{
        vendor: "claude",
        binary: "/private/claude",
        available?: false,
        version: nil,
        auth: :absent
      },
      "codex" => %{
        vendor: "codex",
        binary: "/private/codex",
        available?: true,
        version: "codex 1.2",
        auth: :authenticated
      }
    }

    result = Detect.run(["harness_vendors"], probes: [harness_vendors: fn -> detections end])
    [row] = result["results"]

    assert row["present"]
    assert row["detail"] == "codex"
    assert row["guidance"] == nil

    assert row["vendors"] == [
             %{
               "vendor" => "claude",
               "installed" => false,
               "version" => nil,
               "auth" => "absent",
               "signed_out" => false
             },
             %{
               "vendor" => "codex",
               "installed" => true,
               "version" => "codex 1.2",
               "auth" => "authenticated",
               "signed_out" => false
             }
           ]

    refute Jason.encode!(result) =~ "/private/"
  end

  # M98 D10: a run that failed to sign in marked its agent. `auth` keeps its
  # three published values (released apps decode it as a closed set); the mark
  # is its own optional fact beside it, with a sentence the apps already draw.
  describe "a sign-in mark" do
    test "a marked agent reads signed out, with the sentence that says what clears it" do
      probes = marked_probes({:ok, %{"codex" => %{run_id: "hr_0a1b2c3d4e5f"}}})

      assert %{"results" => [row]} = Detect.run(["harness_vendors"], probes: probes)

      assert [%{"vendor" => "claude"} = claude, %{"vendor" => "codex"} = codex] = row["vendors"]
      assert codex["signed_out"] == true
      assert codex["auth"] == "authenticated"
      assert claude["signed_out"] == false

      assert row["guidance"] ==
               "Codex failed to sign in on its last run on this Mac. Sign in again (run codex " <>
                 "login in a terminal); the next run that works clears this."
    end

    test "marks that cannot be read leave the fact out rather than guess it" do
      probes = marked_probes({:error, :enotdir})

      assert %{"results" => [row]} = Detect.run(["harness_vendors"], probes: probes)
      for vendor <- row["vendors"], do: refute(Map.has_key?(vendor, "signed_out"))
      assert row["guidance"] == nil
    end

    test "a computer whose home is on a server says whose agents these are" do
      probes = Keyword.put(marked_probes({:ok, %{}}), :engine_role, fn -> :device end)

      assert %{"results" => [row]} = Detect.run(["harness_vendors"], probes: probes)

      assert row["guidance"] ==
               "These are this Mac's coding agents. While your home is on your server, " <>
                 "Fermix runs coding agents there, approved and signed in there."
    end
  end

  # M98 G1b-3: the owner pressed Check again, their word that they signed in:
  # the named agents' marks are cleared in this machine's store, and the answer
  # is this machine's agents read again.
  describe "check_agents/2" do
    setup do
      home = FermixTestSupport.SafeRm.make_tmp_dir!("detect-check-agents")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)

      path = MachineStore.path(home)
      store = start_supervised!({MachineStore, name: nil, path: path, open?: true})

      for {vendor, run_id} <- [{"codex", "hr_0a1b2c3d4e5f"}, {"claude", "hr_1234abcd5678"}] do
        mark = %{marked_at: ~U[2026-03-14 09:26:53Z], run_id: run_id}
        :ok = MachineStore.put_mark(vendor, mark, server: store)
      end

      opts = [
        probes: Keyword.take(marked_probes(nil), [:harness_vendors, :machine, :engine_role]),
        sign_in: [path: path, vendor_opts: [codex_home: home, claude_config_dir: home]]
      ]

      %{store: store, opts: opts}
    end

    test "clears the named agents' marks and answers the agents' row", ctx do
      assert {:ok, %{"results" => [row]}} = Detect.check_agents(["claude"], ctx.opts)

      assert row["target"] == "harness_vendors"
      assert [%{"vendor" => "claude"} = claude, %{"vendor" => "codex"} = codex] = row["vendors"]
      assert claude["signed_out"] == false
      assert codex["signed_out"] == true
      assert {:ok, marks} = MachineStore.marks(server: ctx.store)
      assert Map.keys(marks) == ["codex"]
    end

    test "a store that cannot be read is refused with a sentence, nothing cleared", ctx do
      blocked = Path.join(ctx.opts[:sign_in][:path], "not-a-folder/coding.db")
      opts = put_in(ctx.opts, [:sign_in, :path], blocked)

      assert {:error, {:unavailable, "coding_agents", sentence}} =
               Detect.check_agents(["codex"], opts)

      assert sentence =~ "sign-in"
      assert {:ok, marks} = MachineStore.marks(server: ctx.store)
      assert map_size(marks) == 2
    end
  end

  test "no coding CLI carries installation guidance and preserves unverified auth" do
    detections = %{
      "claude" => %{vendor: "claude", available?: false, version: nil, auth: :unverified},
      "codex" => %{vendor: "codex", available?: false, version: nil, auth: :absent}
    }

    result = Detect.run(["harness_vendors"], probes: [harness_vendors: fn -> detections end])
    [row] = result["results"]

    refute row["present"]
    assert row["guidance"] =~ "Install the Codex or Claude Code CLI"
    assert hd(row["vendors"])["auth"] == "unverified"
  end

  defp marked_probes(marks) do
    detections = %{
      "claude" => %{vendor: "claude", available?: true, version: "2.1.9", auth: :unverified},
      "codex" => %{vendor: "codex", available?: true, version: "codex 0.9", auth: :authenticated}
    }

    [
      harness_vendors: fn -> detections end,
      sign_in_marks: fn -> marks end,
      machine: fn -> "this Mac" end,
      engine_role: fn -> :primary end
    ]
  end

  defp vendors(installed) do
    Map.new(["claude", "codex"], fn vendor ->
      {vendor, %{vendor: vendor, available?: installed, version: nil, auth: :absent}}
    end)
  end

  defp vendor_rows do
    Enum.map(["claude", "codex"], fn vendor ->
      %{
        "vendor" => vendor,
        "installed" => true,
        "version" => nil,
        "auth" => "absent",
        "signed_out" => false
      }
    end)
  end

  # The notetaker's sign-in is the one fact the app cannot see for itself: the
  # marker lives beside a browser profile nothing on the wire exposes. Without
  # this row the Meetings pane keeps drawing the idle sign-in control over a
  # notetaker that signed in yesterday.
  describe "the meetbot row" do
    test "both halves installed and signed in reports the sign-in" do
      probes = Keyword.merge(probes(), meetbot_probes(true, true, true))

      assert %{"results" => [row]} = Detect.run(["meetbot"], probes: probes)

      assert row == %{
               "target" => "meetbot",
               "present" => true,
               "detail" => "Signed in to Google",
               "signed_in" => true,
               "available" => true
             }
    end

    test "installed but never signed in says so rather than saying nothing" do
      probes = Keyword.merge(probes(), meetbot_probes(true, true, false))

      assert %{"results" => [row]} = Detect.run(["meetbot"], probes: probes)

      assert row == %{
               "target" => "meetbot",
               "present" => true,
               "detail" => "Not signed in to Google",
               "signed_in" => false,
               "available" => true
             }
    end

    # Absent the notetaker there is nothing to be signed in to, so the row says
    # nothing rather than "not signed in", and the marker is never read.
    test "a sidecar with no browser is absent and carries no sign-in detail" do
      probes =
        Keyword.merge(
          probes(),
          meetbot_installed: fn -> true end,
          meetbot_browser_installed: fn -> false end,
          meetbot_signed_in: fn -> flunk("the sign-in was read for an absent notetaker") end
        )

      assert %{"results" => [row]} = Detect.run(["meetbot"], probes: probes)

      assert row == %{
               "target" => "meetbot",
               "present" => false,
               "detail" => nil,
               "signed_in" => nil,
               "available" => true
             }
    end

    test "no sidecar at all is absent" do
      probes =
        Keyword.merge(
          probes(),
          meetbot_installed: fn -> false end,
          meetbot_browser_installed: fn -> flunk("the browser was read with no sidecar") end,
          meetbot_signed_in: fn -> flunk("the sign-in was read with no sidecar") end
        )

      assert %{"results" => [row]} = Detect.run(["meetbot"], probes: probes)

      assert row == %{
               "target" => "meetbot",
               "present" => false,
               "detail" => nil,
               "signed_in" => nil,
               "available" => true
             }
    end

    # M97 D24: an Always On server has no screen to sign the notetaker in to
    # Google on, so the row says Google Meet cannot run there before the
    # Meetings pane offers anything, in the sentence every surface says. What
    # is installed and signed in is still read as it is.
    test "on an Always On server Google Meet is unavailable, in the D24 sentence" do
      for {installed?, signed_in?} <- [{true, true}, {false, nil}] do
        probes =
          probes()
          |> Keyword.merge(meetbot_probes(installed?, installed?, signed_in?))
          |> Keyword.merge(meet_here: fn -> {:error, :meet_unavailable_on_server} end)

        assert %{"results" => [row]} = Detect.run(["meetbot"], probes: probes)

        assert row == %{
                 "target" => "meetbot",
                 "present" => installed?,
                 "detail" =>
                   "Google Meet is not available on your server yet: the notetaker needs a " <>
                     "Google sign-in on a computer with a screen. Zoom meetings work on your " <>
                     "server.",
                 "signed_in" => signed_in?,
                 "available" => false
               }

        assert row["detail"] == FermixCore.Meetings.meet_unavailable_sentence()
      end
    end
  end

  test "the published target catalog is closed" do
    assert Detect.targets() ==
             ~w(existing_primary claude_code codex_cli ollama harness_vendors meetbot)

    assert Enum.all?(Detect.targets(), &Detect.target?/1)
    refute Detect.target?("something_else")
    refute Detect.target?(:existing_primary)
  end
end

defmodule FermixCore.Management.DetectClaudeCodeTest do
  @moduledoc """
  The `claude_code` row with NO probe injected.

  Every other case here injects the probe, which is exactly how a detection
  that read the credential VALUE — one `security ... -w` per call, and a macOS
  allow dialog with it — stayed invisible to the suite. This case drives the
  default path, so the argv is the daemon's own.

  `async: false` and both variables restored in `on_exit`: `PATH` and `HOME` are
  host state, and a sync module has the VM to itself.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Management.Detect
  alias FermixTestSupport.SafeRm

  setup do
    path = System.get_env("PATH")
    home = System.get_env("HOME")
    dir = SafeRm.make_tmp_dir!("detect_claude_code")
    bin = Path.join(dir, "bin")
    fake_home = Path.join(dir, "home")
    File.mkdir_p!(bin)
    File.mkdir_p!(fake_home)

    System.put_env("PATH", bin <> ":" <> path)
    System.put_env("HOME", fake_home)

    on_exit(fn ->
      System.put_env("PATH", path)
      restore_home(home)
      SafeRm.rm_rf!(dir)
    end)

    %{bin: bin, log: Path.join(dir, "argv.log")}
  end

  test "asks the keychain for presence, never for the value", %{bin: bin, log: log} do
    write_security(bin, log, 0)

    assert %{"results" => [row]} = Detect.run(["claude_code"])
    assert row == %{"target" => "claude_code", "present" => true, "detail" => nil}

    argv = log |> File.read!() |> String.split("\n", trim: true)

    assert argv == ["find-generic-password", "-s", "Claude Code-credentials"]
    refute "-w" in argv
  end

  test "no keychain item and no credentials file is absent", %{bin: bin, log: log} do
    write_security(bin, log, 44)

    assert %{"results" => [row]} = Detect.run(["claude_code"])
    assert row["present"] == false
  end

  defp write_security(bin, log, exit_status) do
    path = Path.join(bin, "security")

    File.write!(path, """
    #!/bin/sh
    for arg in "$@"; do printf '%s\\n' "$arg" >> #{log}; done
    exit #{exit_status}
    """)

    File.chmod!(path, 0o755)
  end

  defp restore_home(nil), do: System.delete_env("HOME")
  defp restore_home(value), do: System.put_env("HOME", value)
end
