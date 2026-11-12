defmodule FermixCore.Management.SettingsThisComputerTest do
  # M97 §7.2: what Fermix on the server may use on this computer, as the
  # "This computer" settings section, answered on this computer alone.
  # async: false: a write to this engine's home reads FERMIX_HOME and puts
  # application environment, both restored.
  use ExUnit.Case, async: false

  alias FermixCore.Computers.Switches
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Settings
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  @apps [:fermix_core, :fermix_channels, :fermix_web]

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_env = for app <- @apps, do: {app, Application.get_all_env(app)}
    tmp = SafeRm.make_tmp_dir!("settings-this-computer")
    System.put_env("FERMIX_HOME", tmp)

    on_exit(fn ->
      Enum.each(previous_env, &restore_env/1)

      if previous_home,
        do: System.put_env("FERMIX_HOME", previous_home),
        else: System.delete_env("FERMIX_HOME")

      SafeRm.rm_rf!(tmp)
    end)

    %{home: tmp}
  end

  test "only a linked computer publishes the section, under Always On" do
    refute Enum.any?(Settings.sections(computer?: false), &(&1.id == "computer"))

    assert %{id: "computer", pane: "always_on", title: "This computer"} in Settings.sections(
             computer?: true
           )

    assert {:error, {:unknown_section, "computer"}} = Settings.get("computer", computer?: false)
  end

  # M97 D27: five rows on a Mac, the master and one switch for each thing the
  # owner decides; Messages only where it runs. The review is this computer's
  # state, history is its recorder's own section, and what reaches the server
  # from the computer has no switch here.
  test "its rows are the master and four switches on a Mac, Messages left out on Linux" do
    Application.put_env(:fermix_core, :computer, Switches.only([:files_and_shell]))
    snapshot = ConfigStore.current_snapshot()

    for {macos?, keys} <- [
          {true,
           ~w(computer_enabled computer_files_and_shell computer_browser computer_computer_use
              computer_imessage)},
          {false,
           ~w(computer_enabled computer_files_and_shell computer_browser computer_computer_use)}
        ] do
      assert {:ok, %{"id" => "computer", "rows" => rows}} =
               Settings.get("computer", computer?: true, macos?: macos?, snapshot: snapshot)

      assert Enum.map(rows, & &1["key"]) == keys
      assert Enum.all?(rows, &(&1["kind"] == "toggle" and &1["restart"] == false))

      assert Enum.map(rows, & &1["label"]) ==
               Enum.take(
                 [
                   "Fermix on your server may use this computer",
                   "Files and commands",
                   "The browser",
                   "Your screen",
                   "Messages"
                 ],
                 length(keys)
               )

      assert %{"value" => true} = Enum.find(rows, &(&1["key"] == "computer_files_and_shell"))
      assert %{"value" => false} = Enum.find(rows, &(&1["key"] == "computer_browser"))
    end
  end

  test "a review in wait is said under the master, and any change here is the review" do
    Application.put_env(
      :fermix_core,
      :computer,
      Switches.only([:files_and_shell], reviewed: false)
    )

    assert {:ok, %{"rows" => [master | _rows]}} =
             Settings.get("computer",
               computer?: true,
               macos?: true,
               snapshot: ConfigStore.current_snapshot()
             )

    assert master["footer"] =~ "Waiting for you to review what Fermix on your server may use"
    assert master["footer"] =~ "Change any switch here"

    assert {:ok, %{"applied" => ["computer_browser"]}} =
             Settings.apply("computer", %{"computer_browser" => true},
               computer?: true,
               macos?: true
             )

    assert Switches.reviewed?(Switches.current())
    assert Switches.on?(Switches.current(), :browser)

    assert {:ok, %{"rows" => [master | _rows]}} =
             Settings.get("computer",
               computer?: true,
               macos?: true,
               snapshot: ConfigStore.current_snapshot()
             )

    assert master["footer"] ==
             "Off stops everything Fermix on your server does here, from its next request."
  end

  test "a write here is saved to this computer's machine file, files and commands as one", ctx do
    Application.put_env(:fermix_core, :computer, Switches.only([:browser]))

    assert {:ok, %{"applied" => ["computer_files_and_shell"]}} =
             Settings.apply("computer", %{"computer_files_and_shell" => true},
               computer?: true,
               macos?: true
             )

    assert {:ok, saved} = Switches.read(ctx.home)
    assert Switches.on?(saved, :files) and Switches.on?(saved, :shell)
    assert Switches.on?(saved, :browser)

    # No row, no write: the review, the old two switches, history and the four
    # that reach the server from the computer.
    for key <- ~w(computer_reviewed computer_files computer_shell computer_history computer_voice) do
      assert {:error, {:invalid_params, ^key, _sentence}} =
               Settings.apply("computer", %{key => true}, computer?: true, macos?: true)
    end

    assert {:error, {:invalid_params, "computer_imessage", _sentence}} =
             Settings.apply("computer", %{"computer_imessage" => true},
               computer?: true,
               macos?: false
             )
  end

  test "the server never writes it: the section is this computer's, refused when forwarded" do
    params = %{"section" => "computer", "values" => %{"computer_files_and_shell" => true}}

    assert Placement.place("settings.apply", params) == :device
    refute Placement.served_forwarded?("settings.apply", params)

    assert {:error, :device_class_method, _details} =
             Placement.device_class_refusal("settings.apply")
  end

  defp restore_env({app, entries}) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(entries, key),
        do: Application.delete_env(app, key)

    for {key, value} <- entries, do: Application.put_env(app, key, value)
  end
end
