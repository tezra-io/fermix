defmodule Fermix.CLI.SignInRoleTest do
  # M75 D5: the tree-less verbs that sign in, sign out, refresh or import a
  # login refuse by name on a home configured as a device or carrying the moved
  # marker, and write nothing: the token file there is a retired copy, and a
  # rotating refresh token has one live owner, the primary.
  #
  # Sync: FERMIX_HOME is the home under test, and refusals print on
  # `:standard_error`, one globally registered device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.AuthCommand
  alias Fermix.CLI.PluginsCommand
  alias FermixCore.Auth.Store
  alias FermixCore.Home.Moved
  alias FermixTestSupport.SafeRm

  @marker %{epoch: 3, moved_at: ~U[2026-10-27 09:30:00Z], to: "aws i-0f3b1c"}

  setup do
    home = SafeRm.make_tmp_dir!("sign_in_role")
    prior = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case prior do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(home)
    end)

    # A stored sign-in a logout would remove and a refresh would rewrite.
    :ok =
      Store.write("anthropic_oauth", %{
        auth_mode: "claude_code_import",
        provider: "anthropic",
        tokens: %{access_token: "invented_at", refresh_token: "invented_rt"},
        expires_at: DateTime.add(DateTime.utc_now(), 30, :second),
        last_refresh: nil
      })

    %{home: home}
  end

  # Public so each case below can name the home it seeds.
  def device_home(home) do
    File.write!(Path.join(home, "config.toml"), ~s([fermix_core.engine]\nrole = "device"\n))
    "This engine runs in the device role; the primary is elsewhere."
  end

  def moved_home(home) do
    :ok = Moved.write(home, @marker)
    "This engine runs in the device role; the primary is aws i-0f3b1c."
  end

  # The exit status and stderr of one run, stdout discarded.
  defp run(fun) do
    err =
      capture_io(:stderr, fn ->
        capture_io(fn -> send(self(), {:status, fun.()}) end)
      end)

    assert_received {:status, status}
    {status, err}
  end

  # Every way a verb could reach a provider, the browser or the keychain, each
  # failing the case if a refusal ever let it through.
  defp unreachable do
    [
      login: fn _opts -> flunk("a refused sign-in must not start") end,
      browser: fn _url -> flunk("a refused sign-in opens no browser") end,
      read_line: fn -> flunk("a refused sign-in reads nothing") end,
      logout: fn _opts -> flunk("a refused sign-out must not revoke") end,
      claude_code: [
        keychain_present?: fn -> flunk("a refused import reads no keychain") end,
        keychain_reader: fn -> flunk("a refused import reads no keychain") end,
        credentials_path: "/nonexistent/fermix-sign-in-role/credentials.json"
      ]
    ]
  end

  # Every file under the home with its bytes: what a refused verb must leave.
  defp written(home) do
    home
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  @auth_verbs [
    ["login"],
    ["login", "--provider", "anthropic", "--import-claude-code"],
    ["login", "--provider", "anthropic", "--setup-token", "sk-ant-oat01-invented"],
    ["login", "--provider", "xai"],
    ["logout"],
    ["logout", "--provider", "anthropic"]
  ]

  @plugin_verbs [
    ["auth", "login", "github"],
    ["auth", "reauthorize", "github"],
    ["auth", "refresh", "github"],
    ["auth", "logout", "github"]
  ]

  for {label, seed} <- [{"a device home", :device_home}, {"a moved home", :moved_home}] do
    @seed seed

    for argv <- @auth_verbs do
      @argv argv

      test "fermix auth #{Enum.join(argv, " ")} refuses on #{label} and writes nothing",
           %{home: home} do
        sentence = apply(__MODULE__, @seed, [home])
        before = written(home)

        assert run(fn -> AuthCommand.run(@argv, unreachable()) end) ==
                 {1, "fermix auth: #{sentence}\n"}

        assert written(home) == before
      end
    end

    for argv <- @plugin_verbs do
      @argv argv

      test "fermix plugins #{Enum.join(argv, " ")} refuses on #{label} and writes nothing",
           %{home: home} do
        sentence = apply(__MODULE__, @seed, [home])
        before = written(home)

        assert run(fn -> PluginsCommand.run(@argv) end) == {1, "fermix plugins: #{sentence}\n"}
        assert written(home) == before
      end
    end
  end

  test "reading what is stored is not refused on a device home", %{home: home} do
    device_home(home)

    assert {0, ""} = run(fn -> AuthCommand.run(["status"], unreachable()) end)
  end

  test "a primary home is not refused: the sign-out runs", %{home: home} do
    {_status, err} =
      run(fn -> AuthCommand.run(["logout", "--provider", "anthropic"], unreachable()) end)

    refute err =~ "device role"
    assert {:error, _gone} = Store.read("anthropic_oauth")
    refute File.exists?(Path.join(home, "moved.json"))
  end
end
