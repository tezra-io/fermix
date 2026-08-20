defmodule FermixCore.Meetings.SignInTest do
  use ExUnit.Case, async: false

  alias FermixCore.Meetings.SignIn

  @fake Path.expand("fake_signin.pl", __DIR__)

  setup do
    prev_home = System.get_env("FERMIX_HOME")
    prev_plugins = Application.get_env(:fermix_core, :plugins)

    home =
      Path.join([
        System.tmp_dir!(),
        "fermix-signin",
        "home-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(home)
    System.put_env("FERMIX_HOME", home)
    # No dev_local build → SidecarInstaller.binary_path/0 reports not-installed.
    Application.delete_env(:fermix_core, :plugins)

    on_exit(fn ->
      case prev_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      case prev_plugins do
        nil -> Application.delete_env(:fermix_core, :plugins)
        value -> Application.put_env(:fermix_core, :plugins, value)
      end

      FermixTestSupport.SafeRm.rm_rf(home)
    end)

    %{home: home}
  end

  # Drives the real spawn path (through the disclaim shim on macOS) against the
  # fake, which speaks the sidecar's NDJSON and exits with the mode's code.
  defp run(mode, opts \\ []) do
    SignIn.run([binary_path: @fake, args: [mode]] ++ opts)
  end

  describe "run/1 verdicts" do
    test "a signed-in exit records the marker", %{home: home} do
      assert run("ok") == {:ok, :signed_in}
      assert File.regular?(Path.join([home, "plugins", "meetbot", "signed_in"]))
    end

    test "the operator closing the window is a cancel" do
      assert run("cancelled") == {:error, :cancelled}
    end

    test "a timed-out flow reports timeout" do
      assert run("timeout") == {:error, :timeout}
    end

    test "any other nonzero exit is a signin failure carrying the code" do
      assert run("error") == {:error, {:signin_failed, 1}}
    end

    test "no marker is written for a failed sign-in", %{home: home} do
      run("cancelled")
      refute File.exists?(Path.join([home, "plugins", "meetbot", "signed_in"]))
    end
  end

  describe "run/1 progress" do
    test "each status line reaches the progress callback in order" do
      me = self()

      assert run("ok", progress: fn event -> send(me, {:signin_event, event}) end) ==
               {:ok, :signed_in}

      assert_received {:signin_event, {:state, :launching}}
      assert_received {:signin_event, {:state, :awaiting_signin}}
      assert_received {:signin_event, {:state, :signed_in}}
      assert_received {:signin_event, {:result, :ok}}
    end
  end

  describe "run/1 refusals" do
    test "refuses loud when the sidecar is not installed" do
      # No binary_path seam and nothing installed → not_installed.
      assert SignIn.run() == {:error, :not_installed}
    end
  end

  describe "spawn_plan/4" do
    test "macOS with no disclaim shim refuses loud — never an undisclaimed spawn" do
      assert {:error, {:disclaim_shim_missing, message}} =
               SignIn.spawn_plan("/bin/meetbot", ["signin"], {:unix, :darwin}, nil)

      assert message =~ "disclaim shim"
    end

    test "macOS with a shim spawns through it" do
      assert SignIn.spawn_plan("/bin/meetbot", ["signin"], {:unix, :darwin}, "/priv/disclaim") ==
               {:ok, {"/priv/disclaim", ["/bin/meetbot", "signin"]}}
    end

    test "other systems spawn the binary directly" do
      assert SignIn.spawn_plan("/bin/meetbot", ["signin"], {:unix, :linux}, nil) ==
               {:ok, {"/bin/meetbot", ["signin"]}}
    end
  end
end
