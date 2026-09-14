defmodule Fermix.CLI.Upgrade.InstallMethodTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Upgrade.InstallMethod

  defmodule StandaloneBuild do
    @moduledoc false
    def linux_package?, do: false
  end

  defmodule PackagedBuild do
    @moduledoc false
    def linux_package?, do: true
  end

  # No ownership tool exists on this host, so every filesystem query would
  # answer "unmanaged". Anything else a test gets came from the identity guard.
  defp no_tools, do: [build_info: StandaloneBuild, find_executable: fn _name -> nil end]

  defp owned_by(tool, exit_status \\ 0) do
    [
      build_info: StandaloneBuild,
      find_executable: fn name -> if name == tool, do: "/usr/bin/#{name}", else: nil end,
      cmd: fn executable, args ->
        send(self(), {:queried, Path.basename(executable), args})
        {"fermix: /usr/bin/fermix", exit_status}
      end
    ]
  end

  test "homebrew Cellar paths are managed by brew" do
    assert {:managed, :homebrew, hint} =
             InstallMethod.detect("/opt/homebrew/Cellar/fermix/0.1.0/bin/fermix", no_tools())

    assert hint == "brew upgrade fermix"
  end

  test "intel-mac brew prefix is detected" do
    assert {:managed, :homebrew, _hint} =
             InstallMethod.detect("/usr/local/Cellar/fermix/0.1.0/bin/fermix", no_tools())
  end

  test "anything outside a package-manager root is unmanaged" do
    assert {:unmanaged, "/opt/local/bin/fermix"} =
             InstallMethod.detect("/opt/local/bin/fermix", no_tools())
  end

  test "follows symlink targets into the brew Cellar" do
    tmp = FermixTestSupport.SafeRm.make_tmp_dir!("symlink")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp) end)

    cellar_dir = Path.join(tmp, "Cellar/fermix/0.1.0/bin")
    File.mkdir_p!(cellar_dir)
    cellar_target = Path.join(cellar_dir, "fermix")
    File.write!(cellar_target, "binary")

    bin_dir = Path.join(tmp, "bin")
    File.mkdir_p!(bin_dir)
    link_path = Path.join(bin_dir, "fermix")
    File.ln_s!(cellar_target, link_path)

    assert {:managed, :homebrew, "brew upgrade fermix"} =
             InstallMethod.detect(link_path, no_tools())
  end

  test "errors when fermix is not on PATH and no path is supplied" do
    # Inject a self-path resolver that reports "not on PATH" so the result is
    # deterministic regardless of whether the host has fermix installed.
    opts = Keyword.put(no_tools(), :resolve_self, fn -> nil end)

    assert {:error, :fermix_not_on_path} = InstallMethod.detect(nil, opts)
  end

  describe "the distribution identity guard" do
    test "a packaged engine refuses with the per-family hint before any query" do
      raising = fn _name -> raise "the identity guard must answer before any filesystem query" end

      assert {:managed, :linux_package, hint} =
               InstallMethod.detect("/usr/bin/fermix",
                 build_info: PackagedBuild,
                 find_executable: raising,
                 resolve_self: raising
               )

      assert hint ==
               "sudo apt update && sudo apt upgrade fermix (Fedora and RHEL: " <>
                 "sudo dnf upgrade fermix; openSUSE: sudo zypper update fermix)"
    end

    test "a packaged engine refuses on a host with no ownership tool installed" do
      assert {:managed, :linux_package, _hint} =
               InstallMethod.detect("/usr/bin/fermix",
                 build_info: PackagedBuild,
                 find_executable: fn _name -> nil end
               )
    end
  end

  describe "host package-database ownership" do
    test "a dpkg-owned binary names the package that now exists" do
      assert {:managed, :dpkg, "sudo apt update && sudo apt upgrade fermix"} =
               InstallMethod.detect("/usr/bin/fermix", owned_by("dpkg"))

      assert_received {:queried, "dpkg", ["-S", "/usr/bin/fermix"]}
    end

    test "an rpm-owned binary carries both front ends in one hint" do
      assert {:managed, :rpm, hint} =
               InstallMethod.detect("/usr/bin/fermix", owned_by("rpm"))

      assert hint == "sudo dnf upgrade fermix (openSUSE: sudo zypper update fermix)"
      assert_received {:queried, "rpm", ["-qf", "/usr/bin/fermix"]}
    end

    test "a pacman-owned binary names the AUR package rather than asserting a command" do
      assert {:managed, :pacman, hint} =
               InstallMethod.detect("/usr/bin/fermix", owned_by("pacman"))

      assert hint ==
               "update the AUR package fermix-bin with your AUR helper " <>
                 "(for example, yay -Syu fermix-bin)"

      assert_received {:queried, "pacman", ["-Qo", "/usr/bin/fermix"]}
    end

    test "a tool that owns nothing leaves the binary unmanaged" do
      assert {:unmanaged, "/usr/bin/fermix"} =
               InstallMethod.detect("/usr/bin/fermix", owned_by("dpkg", 1))
    end

    test "every ownership tool is asked, in order, before answering unmanaged" do
      opts = [
        build_info: StandaloneBuild,
        find_executable: fn name -> "/usr/bin/#{name}" end,
        cmd: fn executable, args ->
          send(self(), {:queried, Path.basename(executable), args})
          {"", 1}
        end
      ]

      assert {:unmanaged, "/usr/bin/fermix"} = InstallMethod.detect("/usr/bin/fermix", opts)

      assert_received {:queried, "brew", ["--prefix"]}
      assert_received {:queried, "dpkg", ["-S", "/usr/bin/fermix"]}
      assert_received {:queried, "rpm", ["-qf", "/usr/bin/fermix"]}
      assert_received {:queried, "pacman", ["-Qo", "/usr/bin/fermix"]}
    end
  end
end
