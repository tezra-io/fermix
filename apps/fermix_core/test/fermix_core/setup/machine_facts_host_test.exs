defmodule FermixCore.Setup.MachineFacts.HostTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Setup.MachineFacts.Host
  alias FermixTestSupport.SafeRm

  describe "timezone/1" do
    setup do
      dir = SafeRm.make_tmp_dir!("machine_facts")
      on_exit(fn -> SafeRm.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "reads the zone from the localtime link's target, on either OS tree", %{dir: dir} do
      mac = Path.join(dir, "mac")
      File.ln_s!("/var/db/timezone/zoneinfo/Europe/Zurich", mac)
      assert Host.timezone(localtime: mac) == {:ok, "Europe/Zurich"}

      linux = Path.join(dir, "linux")
      File.ln_s!("/usr/share/zoneinfo/Asia/Kolkata", linux)
      assert Host.timezone(localtime: linux) == {:ok, "Asia/Kolkata"}
    end

    test "a plain file, a target outside a zoneinfo tree, an unknown zone and no link are errors",
         %{dir: dir} do
      plain = Path.join(dir, "plain")
      File.write!(plain, "UTC0")
      assert Host.timezone(localtime: plain) == :error

      outside = Path.join(dir, "outside")
      File.ln_s!("/etc/hosts", outside)
      assert Host.timezone(localtime: outside) == :error

      unknown = Path.join(dir, "unknown")
      File.ln_s!("/usr/share/zoneinfo/Mars/Olympus_Mons", unknown)
      assert Host.timezone(localtime: unknown) == :error

      assert Host.timezone(localtime: Path.join(dir, "absent")) == :error
    end
  end

  describe "full_name/1" do
    # The runner takes an absolute path; `/bin/echo` stands in for `id` so the
    # default runner is proven without reading the host's account.
    test "the default runner resolves the binary on PATH and runs it" do
      assert Host.full_name(macos?: true, find_executable: fn "id" -> "/bin/echo" end) ==
               {:ok, "-F"}
    end

    test "a binary that is not on PATH is an error, logged" do
      log =
        capture_log(fn ->
          assert Host.full_name(macos?: true, find_executable: fn _binary -> nil end) == :error
        end)

      assert log =~ "executable_not_found"
    end

    test "macOS reads id -F" do
      run = fn "id", ["-F"] -> {:ok, "Ada Lovelace\n"} end

      assert Host.full_name(macos?: true, run: run) == {:ok, "Ada Lovelace"}
    end

    test "Linux reads the GECOS field of the account's passwd entry, up to its first comma" do
      run = fn
        "id", ["-un"] ->
          {:ok, "ada\n"}

        "getent", ["passwd", "ada"] ->
          {:ok, "ada:x:1000:1000:Ada Lovelace,,,:/home/ada:/bin/sh\n"}
      end

      assert Host.full_name(macos?: false, run: run) == {:ok, "Ada Lovelace"}
    end

    test "a blank name, a failed command and a malformed entry are errors, each logged" do
      log =
        capture_log(fn ->
          assert Host.full_name(macos?: true, run: fn _binary, _args -> {:ok, "  \n"} end) ==
                   :error

          assert Host.full_name(macos?: true, run: fn _binary, _args -> {:error, :enoent} end) ==
                   :error

          malformed = fn
            "id", ["-un"] -> {:ok, "ada"}
            "getent", _args -> {:ok, "not a passwd line"}
          end

          assert Host.full_name(macos?: false, run: malformed) == :error
        end)

      assert log =~ "has no full name"
      assert log =~ ":enoent"
      assert log =~ "malformed_passwd_entry"
    end
  end
end
