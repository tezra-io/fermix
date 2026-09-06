defmodule FermixCore.Management.DetectTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Detect

  defp probes do
    [
      existing_primary: fn -> {:ok, :openai_codex} end,
      claude_code: fn -> true end,
      codex_cli: fn -> false end,
      ollama: fn -> {:error, :econnrefused} end,
      harness_vendors: fn -> vendors(true) end
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
      assert row |> Map.drop(~w(vendors guidance)) |> Map.keys() |> Enum.sort() ==
               ~w(detail present target)

      assert is_boolean(row["present"])
      assert is_nil(row["detail"]) or is_binary(row["detail"])
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
             %{"vendor" => "claude", "installed" => false, "version" => nil, "auth" => "absent"},
             %{
               "vendor" => "codex",
               "installed" => true,
               "version" => "codex 1.2",
               "auth" => "authenticated"
             }
           ]

    refute Jason.encode!(result) =~ "/private/"
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

  defp vendors(installed) do
    Map.new(["claude", "codex"], fn vendor ->
      {vendor, %{vendor: vendor, available?: installed, version: nil, auth: :absent}}
    end)
  end

  defp vendor_rows do
    Enum.map(["claude", "codex"], fn vendor ->
      %{"vendor" => vendor, "installed" => true, "version" => nil, "auth" => "absent"}
    end)
  end

  test "the published target catalog is closed" do
    assert Detect.targets() == ~w(existing_primary claude_code codex_cli ollama harness_vendors)
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
