defmodule FermixCore.Management.HomeUnlistedTest do
  # M97 F3, F9: `home.status` asked before this engine's channels tree is up
  # (its own boot, or `fermix home status` reading a stopped Fermix) lists no
  # computer and says nothing in the log, while an Always On server still
  # holds its update: rows not read yet are not known, never none. async:
  # false: it asserts what is and is not logged.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Releases
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @at ~U[2031-05-04 12:00:00Z]
  @listed "the home's computers could not be listed"

  setup do
    home = SafeRm.make_tmp_dir!("management_home_unlisted")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    %{home: home}
  end

  test "not started lists none and says nothing; a stopped link is said", %{home: home} do
    log =
      capture_log(fn ->
        assert {:ok, %{"computers" => [], "update" => update}} = status(home, :not_started)
        assert %{"held" => %{"sentence" => held}} = update
        assert held =~ "once Fermix can list your computers again"
      end)

    refute log =~ @listed

    log = capture_log(fn -> assert {:ok, %{"computers" => []}} = status(home, :not_running) end)
    assert log =~ "#{@listed}: :not_running"
  end

  defp status(home, reason) do
    digests =
      for version <- ["9.9.9", "9.10.0"],
          do: "#{version} #{String.duplicate("d", 64)} fermix_always_on.sh"

    rows = ["format 1", "latest 9.10.0"] ++ digests ++ ["app 9.10.0 linux 1.4.0"]
    {:ok, parsed} = Releases.parse(Enum.join(rows, "\n") <> "\n")

    home_opts = [
      home: home,
      engine_role: %{role: :primary, primary: nil},
      config: [],
      scheduler: nil,
      profile: "general",
      now: @at,
      disk_usage: fn _home -> {:ok, %{used: 0.4, nearly_full: false}} end,
      snapshot_targets: Scheduler.targets(:server),
      webhook_settings: fn -> %{whatsapp: [], cues: [], web_port: 4030} end,
      version: "9.9.9",
      always_on_server: true,
      release_table: fn -> {:ok, parsed, @at, nil} end,
      computers: {:error, reason}
    ]

    Router.route(
      %{request_id: "req-1", protocol_version: 2, method: "home.status", params: %{}},
      operation_opts: [home: home_opts]
    )
  end
end
