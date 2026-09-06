defmodule FermixCore.Boot.PathBaselineTest do
  @moduledoc """
  The PATH baseline from M34 native setup §7.9.

  `PATH` is process-global, so every case that mutates it establishes it in its
  own `setup` and restores it in `on_exit`, and the module is `async: false`.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Boot.PathBaseline
  alias FermixCore.Harness.Vendors
  alias FermixTestSupport.SafeRm

  setup do
    original = System.get_env("PATH")

    on_exit(fn ->
      case original do
        nil -> System.delete_env("PATH")
        value -> System.put_env("PATH", value)
      end
    end)

    :ok
  end

  test "the binary directory leads and the user bin directory is last" do
    dirs = PathBaseline.dirs(os: :darwin, binary_dir: "/opt/fermix/bin", user_home: "/home/o")

    assert List.first(dirs) == "/opt/fermix/bin"
    assert List.last(dirs) == "/home/o/.local/bin"
    assert "/opt/homebrew/bin" in dirs
    assert dirs == Enum.uniq(dirs)
  end

  test "a binary directory that is already a standard directory is not duplicated" do
    dirs = PathBaseline.dirs(os: :darwin, binary_dir: "/usr/local/bin", user_home: "/home/o")

    assert Enum.count(dirs, &(&1 == "/usr/local/bin")) == 1
  end

  test "linux carries no homebrew prefix" do
    dirs = PathBaseline.dirs(os: :linux, user_home: "/home/o")

    refute "/opt/homebrew/bin" in dirs
    assert "/usr/local/bin" in dirs
  end

  # Appending only. A leading entry would silently change resolution for every
  # colliding binary the operator's own PATH already chose.
  test "ensure! appends what is missing and never reorders what is present" do
    System.put_env("PATH", "/usr/bin:/bin")

    added = PathBaseline.ensure!(os: :darwin, user_home: "/home/o")

    assert "/opt/homebrew/bin" in added
    dirs = PathBaseline.current_dirs()
    assert Enum.take(dirs, 2) == ["/usr/bin", "/bin"]
    assert List.last(dirs) == "/home/o/.local/bin"
  end

  test "ensure! on an already complete PATH adds nothing" do
    System.put_env("PATH", Enum.join(PathBaseline.dirs(os: :darwin, user_home: "/home/o"), ":"))

    assert PathBaseline.ensure!(os: :darwin, user_home: "/home/o") == []
  end

  # The fidelity half of the sanitizer pair: proving nothing leaks says nothing
  # about whether the child can still resolve what it needs. `available?/2` is
  # called with NO `:find_executable` override on purpose — a stubbed seam would
  # prove nothing about the process PATH the baseline actually mutated.
  test "a vendor CLI in the user bin directory resolves after the baseline is applied" do
    home = SafeRm.make_tmp_dir!("path_baseline_home")
    on_exit(fn -> SafeRm.rm_rf!(home) end)

    bin = Path.join(home, ".local/bin")
    File.mkdir_p!(bin)
    fake = Path.join(bin, "codex")
    File.write!(fake, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake, 0o755)

    System.put_env("PATH", "/usr/bin:/bin")
    refute Vendors.available?("codex", [])

    PathBaseline.ensure!(os: PathBaseline.os_family(), user_home: home)

    assert Vendors.available?("codex", [])
  end

  test "missing_dirs names exactly what ensure! would add" do
    System.put_env("PATH", "/usr/bin:/bin")
    opts = [os: :darwin, user_home: "/home/o"]

    missing = PathBaseline.missing_dirs(opts)

    assert PathBaseline.ensure!(opts) == missing
    assert PathBaseline.missing_dirs(opts) == []
  end
end
