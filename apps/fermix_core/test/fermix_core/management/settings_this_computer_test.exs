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

  test "its rows are the master, the review and one switch per offer, none needing a restart" do
    Application.put_env(:fermix_core, :computer, Switches.only([:files], reviewed: false))

    assert {:ok, %{"id" => "computer", "rows" => rows}} =
             Settings.get("computer", computer?: true, snapshot: ConfigStore.current_snapshot())

    keys = Enum.map(rows, & &1["key"])

    assert keys ==
             ["computer_enabled", "computer_reviewed"] ++
               Enum.map(Switches.offers(), &"computer_#{&1}")

    assert Enum.all?(rows, &(&1["kind"] == "toggle" and &1["restart"] == false))

    assert %{"value" => false, "read_only" => false} =
             Enum.find(rows, &(&1["key"] == "computer_reviewed"))

    assert %{"value" => true} = Enum.find(rows, &(&1["key"] == "computer_files"))
  end

  test "a write here is the review, saved to this computer's machine file", ctx do
    Application.put_env(:fermix_core, :computer, Switches.only([:files], reviewed: false))

    assert {:ok, %{"applied" => ["computer_browser"]}} =
             Settings.apply("computer", %{"computer_browser" => true}, computer?: true)

    assert Switches.reviewed?(Switches.current())
    assert Switches.on?(Switches.current(), :browser)
    assert {:ok, saved} = Switches.read(ctx.home)
    assert Switches.on?(saved, :browser) and Switches.on?(saved, :files)

    # Once reviewed, the review is shown and not written.
    assert {:error, {:invalid_params, "computer_reviewed", _sentence}} =
             Settings.apply("computer", %{"computer_reviewed" => false}, computer?: true)
  end

  test "the server never writes it: the section is this computer's, refused when forwarded" do
    params = %{"section" => "computer", "values" => %{"computer_files" => true}}

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
