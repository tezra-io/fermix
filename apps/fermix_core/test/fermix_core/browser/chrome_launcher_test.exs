defmodule FermixCore.Browser.ChromeLauncherTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Config

  @dir "/home/u/.fermix/browser/profiles/abc/fermix"

  defp ps_line(pid, dir, port) do
    "#{pid} /Applications/Google Chrome.app/Contents/MacOS/Google Chrome " <>
      "--user-data-dir=#{dir} --remote-debugging-port=#{port} --headless=new about:blank"
  end

  describe "parse_ps_output/2 (existing-Chrome reuse detection)" do
    test "finds the pid and cdp port for an exact user-data-dir match" do
      output = Enum.join([ps_line(78_009, @dir, 18_805), "999 /usr/bin/something else"], "\n")
      assert {78_009, 18_805} = ChromeLauncher.parse_ps_output(output, @dir)
    end

    test "does not match a different profile that shares a path prefix" do
      # ".../fermix" must not match a process for ".../fermix_visible".
      output = ps_line(81_806, @dir <> "_visible", 18_806)
      assert :none = ChromeLauncher.parse_ps_output(output, @dir)
    end

    test "returns :none when no process owns the dir" do
      output = "111 /usr/bin/Xorg\n222 /Applications/Safari.app/Contents/MacOS/Safari"
      assert :none = ChromeLauncher.parse_ps_output(output, @dir)
    end

    test "ignores a matching dir with no debugging port" do
      output =
        "500 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=#{@dir}"

      assert :none = ChromeLauncher.parse_ps_output(output, @dir)
    end
  end

  describe "attach/4" do
    test "returns :none for non-managed profiles" do
      {:ok, config} = Config.current()
      assert :none = ChromeLauncher.attach(config, %{mode: :existing_session}, "owner", "user")
    end
  end
end
