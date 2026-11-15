defmodule FermixCore.Management.SettingsCodingMachineTest do
  # M98 D5: whether coding agents may run on this machine is its own setting,
  # the coding pane's section named for this machine, published only where
  # the coding rail runs. A computer whose home is on its server publishes
  # none and drops its server's (G1a: the Mac's pane once showed its own
  # agents beside a switch that approved them on the server).
  # async: false: a write reads FERMIX_HOME and puts application
  # environment, both restored.
  use ExUnit.Case, async: false

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Router
  alias FermixCore.Management.Settings
  alias FermixCore.Management.Settings.CodingMachine
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.MachineFile
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @apps [:fermix_core, :fermix_channels, :fermix_web]

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_env = for app <- @apps, do: {app, Application.get_all_env(app)}
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()
    tmp = SafeRm.make_tmp_dir!("settings-coding-machine")
    System.put_env("FERMIX_HOME", tmp)
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      Enum.each(previous_env, &restore_env/1)
      SecretWriterStub.reset()

      if previous_home,
        do: System.put_env("FERMIX_HOME", previous_home),
        else: System.delete_env("FERMIX_HOME")

      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp}
  end

  test "published where the coding rail runs, named for this machine, before the home's section" do
    for {macos?, title} <- [{true, "This Mac"}, {false, "This computer"}] do
      sections = Settings.sections(macos?: macos?, computer?: false)

      assert %{id: "harness_machine", pane: "coding", title: ^title} =
               Enum.find(sections, &(&1.id == "harness_machine"))

      # Both apps draw the coding pane's sections in this order.
      assert for(%{pane: "coding", id: id} <- sections, do: id) == ["harness_machine", "harness"]
    end
  end

  test "a computer whose home is on its server publishes none and reads none" do
    refute Enum.any?(
             Settings.sections(macos?: true, computer?: true),
             &(&1.id == "harness_machine")
           )

    assert {:error, {:unknown_section, "harness_machine"}} =
             Settings.get("harness_machine", macos?: true, computer?: true)
  end

  test "its one row names this machine, and the home's section keeps the preferred tool" do
    snapshot = with_harness(approved: true, default_vendor: "codex")

    for {macos?, label} <- [
          {true, "Allow coding agents to run on this Mac"},
          {false, "Allow coding agents to run on this computer"}
        ] do
      assert {:ok, %{"id" => "harness_machine", "rows" => [row]}} =
               Settings.get("harness_machine",
                 macos?: macos?,
                 computer?: false,
                 snapshot: snapshot
               )

      assert %{
               "key" => "harness_approved",
               "kind" => "toggle",
               "label" => ^label,
               "value" => true,
               "restart" => true
             } = row
    end

    assert {:ok, %{"rows" => rows}} = Settings.get("harness", snapshot: snapshot)
    assert Enum.map(rows, & &1["key"]) == ["harness_default_vendor"]
  end

  test "a write approves coding agents in this machine's file alone", ctx do
    assert {:ok, %{"applied" => ["harness_approved"]}} =
             Settings.apply("harness_machine", %{"harness_approved" => true}, computer?: false)

    assert Application.get_env(:fermix_core, :harness)[:approved] == true
    machine = File.read!(MachineFile.path(ctx.home))
    assert ConfigText.value(machine, "fermix_core.harness", "approved") == {:ok, "true"}
    refute File.read!(Path.join(ctx.home, "config.toml")) =~ "approved"
  end

  # M97 §19.9 (D28, revising M98 D5): after a move the approval is the
  # server's, a plain id a linked computer sends to it; the server's own
  # words name it "this server".
  test "the section is the server's after a move: sent to it, and served there" do
    params = %{"section" => "harness_machine", "values" => %{"harness_approved" => true}}

    assert Placement.place("settings.get", %{"section" => "harness_machine"}) == :primary
    assert Placement.place("settings.apply", params) == :primary
    assert Placement.served_forwarded?("settings.apply", params)
    assert Placement.machine_write?("settings.apply", params)

    assert [%{id: "harness_machine", title: "This server"}] =
             CodingMachine.sections(macos?: false, computer?: false, server_primary?: true)

    assert [%{"label" => "Allow coding agents to run on this server"}] =
             CodingMachine.rows("harness_machine", %{}, macos?: false, server_primary?: true)
  end

  # End to end through the composed inventory: the server's approval is
  # listed under its name where it applies the rule, and left out where it
  # does not; the linked Mac publishes none of its own.
  test "a linked computer lists its server's coding approval, and none of its own" do
    server = fn request, _opts ->
      Router.route(request, macos?: false, computer?: false, server_primary?: true)
    end

    request = %{
      request_id: "req-1",
      protocol_version: 2,
      method: "settings.sections",
      params: %{}
    }

    assert {:ok, %{"sections" => served}} = server.(request, [])
    assert Enum.any?(served, &(&1["id"] == "harness_machine"))

    for takes? <- [true, false] do
      assert {:ok, %{"sections" => composed}} =
               Router.route(request,
                 macos?: true,
                 computer?: true,
                 primary_forward: server,
                 linked_server: %{name: "garden server", machine_settings: takes?}
               )

      coding = Enum.filter(composed, &(&1["pane"] == "coding"))

      assert coding ==
               if(takes?,
                 do: [
                   %{"id" => "harness_machine", "pane" => "coding", "title" => "garden server"},
                   %{"id" => "harness", "pane" => "coding", "title" => "Coding agents"}
                 ],
                 else: [%{"id" => "harness", "pane" => "coding", "title" => "Coding agents"}]
               )

      refute Enum.any?(composed, &(&1["id"] == "computer.harness_machine"))
    end
  end

  defp with_harness(harness),
    do:
      Map.update!(
        ConfigStore.current_snapshot(),
        :fermix_core,
        &Keyword.put(&1, :harness, harness)
      )

  defp restore_env({app, entries}) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(entries, key),
        do: Application.delete_env(app, key)

    for {key, value} <- entries, do: Application.put_env(app, key, value)
  end
end
