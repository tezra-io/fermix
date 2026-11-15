defmodule FermixCore.Management.SettingsComputerHistoryTest do
  # The computer_history section's Apps row, read from a snapshot handed in
  # with the recorder's system named, so nothing here reads this machine.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Epoch
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Settings.Tools
  alias FermixTestSupport.SafeRm

  @snapshot %{fermix_core: [computer_history: [enabled: false, apps: []]]}

  # M97 stage 4, D1: on Linux an entry is the app's name on the accessibility
  # bus, matched exactly, which an app need not show anywhere, so the row
  # says so in the engine's words and names no app of its own.
  test "on a Linux recorder the Apps row says what an entry is" do
    info = apps_row(:linux)["info"]

    assert info ==
             "Each entry is an app's name on the accessibility bus, matched exactly, which " <>
               "can differ from the name the app shows. /history status names the listed " <>
               "apps that recorded nothing."

    assert Copy.violations(info, :prose) == []
  end

  test "on a Mac the Apps row is as it was" do
    row = apps_row(:macos)
    assert row["info"] == nil
    assert row["footer"] == "Only these apps are watched."
  end

  # M97 §19.2: nobody sits at an Always On server, so it publishes neither
  # its screen's section nor its history's, by the rule the recorder asks
  # (`Home.AlwaysOn.here?/1`). A Linux computer that took the home back,
  # another computer still linked to it, is no server and keeps both.
  test "the screen's and history's sections follow the Always On server rule" do
    home = SafeRm.make_tmp_dir!("tools_sections")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 3)
    server = %{install: :linux_package_cli, os: :linux, linux_app: false}
    primary = %{role: :primary, primary: nil}

    ids = fn host ->
      [always_on: [home: home, booted: primary, host_facts: host]]
      |> Tools.sections()
      |> Enum.map(& &1.id)
    end

    refute "computer_history" in ids.(server)
    refute "computer_use" in ids.(server)
    assert "computer_history" in ids.(%{server | linux_app: true})
    assert "computer_use" in ids.(%{server | linux_app: true})
  end

  defp apps_row(system) do
    "computer_history"
    |> Tools.rows(@snapshot, history_system: system)
    |> Enum.find(&(&1["key"] == "computer_history_apps"))
  end
end
