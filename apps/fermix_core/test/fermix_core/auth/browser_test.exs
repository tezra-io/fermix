defmodule FermixCore.Auth.BrowserTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.Browser

  defp ok_runner, do: fn _path, _args -> {"", 0} end
  defp fail_runner(code, output), do: fn _path, _args -> {output, code} end
  defp finder_returns(path), do: fn _exe -> path end
  defp finder_missing, do: fn _exe -> nil end

  describe "open/2" do
    test "uses `open` on macOS" do
      finder = fn
        "open" -> "/usr/bin/open"
        _other -> nil
      end

      runner = fn path, args ->
        send(self(), {:invoked, path, args})
        {"", 0}
      end

      assert :ok =
               Browser.open("http://localhost:4001/setup",
                 os: {:unix, :darwin},
                 finder: finder,
                 runner: runner
               )

      assert_received {:invoked, "/usr/bin/open", ["http://localhost:4001/setup"]}
    end

    test "uses `xdg-open` on Linux" do
      finder = fn
        "xdg-open" -> "/usr/bin/xdg-open"
        _other -> nil
      end

      runner = fn path, args ->
        send(self(), {:invoked, path, args})
        {"", 0}
      end

      assert :ok =
               Browser.open("http://localhost:4001/setup",
                 os: {:unix, :linux},
                 finder: finder,
                 runner: runner
               )

      assert_received {:invoked, "/usr/bin/xdg-open", ["http://localhost:4001/setup"]}
    end

    test "uses `cmd /c start` on Windows" do
      finder = fn
        "cmd" -> "C:\\Windows\\System32\\cmd.exe"
        _other -> nil
      end

      runner = fn path, args ->
        send(self(), {:invoked, path, args})
        {"", 0}
      end

      assert :ok =
               Browser.open("http://localhost:4001/setup",
                 os: {:win32, :nt},
                 finder: finder,
                 runner: runner
               )

      assert_received {:invoked, "C:\\Windows\\System32\\cmd.exe",
                       ["/c", "start", "", "http://localhost:4001/setup"]}
    end

    test "returns {:error, :no_opener} when the executable is not on PATH" do
      assert {:error, :no_opener} =
               Browser.open("http://localhost:4001/setup",
                 os: {:unix, :linux},
                 finder: finder_missing(),
                 runner: ok_runner()
               )
    end

    test "returns {:error, {:opener_failed, code, output}} on non-zero exit" do
      assert {:error, {:opener_failed, 2, "boom"}} =
               Browser.open("http://localhost:4001/setup",
                 os: {:unix, :darwin},
                 finder: finder_returns("/usr/bin/open"),
                 runner: fail_runner(2, "boom")
               )
    end
  end
end
