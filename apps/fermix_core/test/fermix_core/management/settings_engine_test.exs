defmodule FermixCore.Management.SettingsEngineTest do
  @moduledoc """
  The `engine` settings section (M75 §16): the role row in every role, the
  executor switch in the device role only, a write through the settings door
  saved and loaded back, and what is refused. Every case runs in its own home
  with the application environment it touches restored on exit, as
  `settings_snapshots_test.exs` does.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Home.Role
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Router
  alias FermixCore.Management.Settings
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "invented-vm"}
  @candidate %{role: :candidate, primary: nil}
  @core_keys [:engine, :secret_writer]
  @successes Application.app_dir(:fermix_core, "priv/management/fixtures/success.jsonl")

  setup do
    home = System.get_env("FERMIX_HOME")
    core = Map.new(@core_keys, fn key -> {key, Application.fetch_env(:fermix_core, key)} end)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    tmp = SafeRm.make_tmp_dir!("management_settings_engine")
    System.put_env("FERMIX_HOME", tmp)
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(key, value) end)
      if home, do: System.put_env("FERMIX_HOME", home), else: System.delete_env("FERMIX_HOME")
      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp}
  end

  test "the section is published under the Always On pane and configures this computer" do
    sections = Settings.sections()
    ids = Enum.map(sections, & &1.id)

    assert %{id: "engine", pane: "always_on", title: "This computer"} in sections

    assert Enum.find_index(ids, &(&1 == "engine")) + 1 ==
             Enum.find_index(ids, &(&1 == "snapshots"))

    assert "engine" in Placement.device_sections()
    assert Placement.place("settings.apply", %{"section" => "engine"}) == :device
  end

  test "a primary sees its role, read-only, and no executor switch" do
    assert {:ok, %{"id" => "engine", "rows" => [role]}} =
             Settings.get("engine", engine_role: @primary)

    assert %{
             "key" => "engine_role",
             "kind" => "choice",
             "value" => "primary",
             "read_only" => true,
             "restart" => false,
             "footer" => "Fermix's chats, memory and channels live on this computer."
           } = role

    assert Enum.map(role["options"], & &1["value"]) == ~w(primary device candidate)
  end

  test "a candidate sees its role and no executor switch" do
    assert {:ok, %{"rows" => [%{"value" => "candidate", "footer" => footer}]}} =
             Settings.get("engine", engine_role: @candidate)

    assert footer == "This computer waits to become the primary through a move."
  end

  test "a desktop sees its role naming the primary, and the executor switch, on by default" do
    Application.put_env(:fermix_core, :engine, role: :device)

    assert {:ok, %{"rows" => [role, executor]}} = Settings.get("engine", engine_role: @device)

    assert role["value"] == "device"
    assert role["footer"] =~ "Fermix lives on invented-vm;"

    assert %{
             "key" => "engine_executor",
             "kind" => "toggle",
             "value" => true,
             "read_only" => false,
             "restart" => false
           } = executor

    unnamed = %{@device | primary: nil}

    assert {:ok, %{"rows" => [unnamed_role, _executor]}} =
             Settings.get("engine", engine_role: unnamed)

    assert unnamed_role["footer"] =~ "Fermix lives on its primary;"
  end

  test "the executor switch saves to config.toml, loads back and applies at once", %{home: home} do
    Application.put_env(:fermix_core, :engine, role: :device)

    assert {:ok, result} =
             Settings.apply("engine", %{"engine_executor" => false}, engine_role: @device)

    assert result["applied"] == ["engine_executor"]
    # No restart reason names it: the section is read live.
    refute Enum.any?(result["restart"]["reasons"], &(&1["section"] == "engine"))

    contents = File.read!(Path.join(home, "config.toml"))
    assert contents =~ ~s([fermix_core.engine]\nrole = "device"\nexecutor = false)

    # Applied to this engine at once: the executor reads the section per action.
    assert Application.get_env(:fermix_core, :engine) == [role: :device, executor: false]
    refute Role.executor?(Application.get_env(:fermix_core, :engine))

    # Loaded back from the file, it is the same section, and the row reads it.
    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    assert Keyword.fetch!(loaded.fermix_core, :engine) == [role: :device, executor: false]
    assert :ok = ConfigStore.apply_snapshot(loaded)

    assert {:ok, %{"rows" => [_role, %{"value" => false}]}} =
             Settings.get("engine", engine_role: @device)

    assert {:ok, _on} =
             Settings.apply("engine", %{"engine_executor" => true}, engine_role: @device)

    assert File.read!(Path.join(home, "config.toml")) =~
             ~s([fermix_core.engine]\nrole = "device"\nexecutor = true)
  end

  test "the role, a non-boolean switch and the switch off the device role are refused" do
    Application.put_env(:fermix_core, :engine, role: :device)

    assert {:error,
            {:invalid_params, "engine_role", "This setting is shown here and changed elsewhere."}} =
             Settings.apply("engine", %{"engine_role" => "primary"}, engine_role: @device)

    assert {:error, {:invalid_params, "engine_executor", "This setting takes true or false."}} =
             Settings.apply("engine", %{"engine_executor" => "no"}, engine_role: @device)

    assert {:error,
            {:invalid_params, "engine_executor", "This section has no setting by that name."}} =
             Settings.apply("engine", %{"engine_executor" => false}, engine_role: @primary)

    assert Application.get_env(:fermix_core, :engine) == [role: :device]
  end

  test "the router hands its engine role to the section" do
    request = %{
      request_id: "req-1",
      protocol_version: 2,
      method: "settings.get",
      params: %{"section" => "engine"}
    }

    assert {:ok, %{"rows" => [_role, %{"key" => "engine_executor"}]}} =
             Router.route(request, engine_role: @device)

    assert {:ok, %{"rows" => [%{"key" => "engine_role"}]}} =
             Router.route(request, engine_role: @primary)
  end

  # The golden is what the row builder writes for the desktop it illustrates,
  # sentences included, so a word changed in Elixir fails here rather than
  # reaching an app that renders the golden's.
  test "the golden engine section is the one a linked desktop publishes" do
    golden =
      @successes
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["name"] == "settings_get_engine"))
      |> get_in(["response", "result"])

    snapshot = %{fermix_core: [engine: [role: :device]]}
    device = %{@device | primary: "fermix-vm"}

    assert {:ok, view} = Settings.get("engine", engine_role: device, snapshot: snapshot)
    assert golden == view
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:fermix_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:fermix_core, key)
end
