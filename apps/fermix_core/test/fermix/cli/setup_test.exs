defmodule Fermix.CLI.SetupTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Fermix.CLI.Setup

  test "default desktop standalone setup uses the web launcher" do
    parent = self()

    assert 0 =
             Setup.run([],
               standalone?: fn -> true end,
               display?: fn -> true end,
               web_launcher: fn opts ->
                 send(parent, {:web_launcher, Keyword.take(opts, [:scope, :no_browser])})
                 :ok
               end,
               runtime: unexpected_runtime(parent)
             )

    assert_receive {:web_launcher, launch_opts}
    assert Map.new(launch_opts) == %{scope: :user, no_browser: false}
    refute_receive {:runtime, _opts}
  end

  test "headless standalone setup uses the terminal runtime" do
    parent = self()

    assert 0 =
             Setup.run([],
               standalone?: fn -> true end,
               display?: fn -> false end,
               setup_ready?: fn -> false end,
               runtime: runtime(parent),
               web_launcher: unexpected_web_launcher(parent)
             )

    assert_receive {:runtime, []}
    refute_receive {:web_launcher, _opts}
  end

  test "--web forces web setup without opening a browser when --no-browser is present" do
    parent = self()

    assert 0 =
             Setup.run(["--web", "--no-browser", "--system"],
               standalone?: fn -> true end,
               display?: fn -> false end,
               web_launcher: fn opts ->
                 keys = [:scope, :no_browser, :ssh_hint]
                 send(parent, {:web_launcher, Keyword.take(opts, keys)})
                 :ok
               end,
               runtime: unexpected_runtime(parent)
             )

    assert_receive {:web_launcher, launch_opts}
    assert Map.new(launch_opts) == %{scope: :system, no_browser: true, ssh_hint: true}
  end

  test "terminal setup activates the service after setup is ready" do
    parent = self()
    service = fake_service(parent, installed?: false)

    output =
      capture_io(fn ->
        assert 0 =
                 Setup.run(["--cli"],
                   standalone?: fn -> true end,
                   display?: fn -> false end,
                   runtime: runtime(parent),
                   setup_ready?: fn -> true end,
                   service: service,
                   web_launcher: unexpected_web_launcher(parent)
                 )
      end)

    assert_receive {:runtime, []}
    assert_receive {:service, :installed?, :user, []}
    assert_receive {:service, :install, :user, []}
    assert_receive {:service, :start, :user, []}
    assert output =~ "Fermix is running (user service)."
  end

  test "--cli and --no-service use terminal runtime" do
    parent = self()
    service = fake_service(parent, installed?: false)

    assert 0 =
             Setup.run(["--cli", "--no-service"],
               standalone?: fn -> true end,
               display?: fn -> true end,
               service: service,
               setup_ready?: fn -> true end,
               runtime: runtime(parent),
               web_launcher: unexpected_web_launcher(parent)
             )

    assert_receive {:runtime, opts}
    assert Keyword.get(opts, :no_service) == true
    refute_receive {:service, _, _, _}
  end

  test "provided setup answers keep the existing terminal behavior" do
    parent = self()

    assert 0 =
             Setup.run(["--provider", "openai", "--openai-api-key", "sk-test"],
               standalone?: fn -> true end,
               display?: fn -> true end,
               setup_ready?: fn -> false end,
               runtime: runtime(parent),
               web_launcher: unexpected_web_launcher(parent)
             )

    assert_receive {:runtime, opts}
    assert Keyword.get(opts, :provider) == "openai"
    assert Keyword.get(opts, :openai_api_key) == "sk-test"
  end

  test "--acp-enabled is a recognized answer that routes to the terminal runtime" do
    parent = self()

    assert 0 =
             Setup.run(["--acp-enabled"],
               standalone?: fn -> true end,
               display?: fn -> true end,
               setup_ready?: fn -> false end,
               runtime: runtime(parent),
               web_launcher: unexpected_web_launcher(parent)
             )

    assert_receive {:runtime, opts}
    assert Keyword.get(opts, :acp_enabled) == true
  end

  # The mobile channel is feature-flagged with no setup surface: every mobile
  # switch is unregistered, so each one has to be refused by the ordinary
  # unknown-flag path rather than quietly parsed and dropped. Looping over the
  # whole withdrawn set keeps a later re-addition from slipping past one case.
  test "every withdrawn mobile switch is rejected like any unregistered flag" do
    argv = [
      ["--mobile-enabled"],
      ["--no-mobile-enabled"],
      ["--mobile-port", "4555"],
      ["--mobile-push-enabled"],
      ["--mobile-push-team-id", "ABCDE12345"],
      ["--mobile-push-key-id", "KEY987"],
      ["--mobile-push-key", "p8-fixture"],
      ["--mobile-push-topic", "io.tezra.fermix.app"],
      ["--mobile-push-environment", "development"]
    ]

    Enum.each(argv, fn args ->
      parent = self()

      stderr =
        capture_io(:stderr, fn ->
          assert 1 =
                   Setup.run(args,
                     standalone?: fn -> true end,
                     display?: fn -> true end,
                     runtime: unexpected_runtime(parent),
                     web_launcher: unexpected_web_launcher(parent)
                   )
        end)

      assert stderr =~ "invalid options", "expected #{inspect(args)} to be refused"
      refute_received {:runtime, _opts}
      refute_received {:web_launcher, _opts}
    end)
  end

  test "rejects an unregistered flag next to the acp switch" do
    stderr =
      capture_io(:stderr, fn ->
        assert 1 =
                 Setup.run(["--acp-enable"],
                   standalone?: fn -> true end,
                   display?: fn -> true end
                 )
      end)

    assert stderr =~ "invalid options"
  end

  test "rejects contradictory web and terminal flags" do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert 1 =
                 Setup.run(["--web", "--cli"],
                   standalone?: fn -> true end,
                   display?: fn -> true end
                 )
      end)

    assert stderr =~ "--web cannot be combined"
  end

  test "rejects web setup without service activation" do
    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert 1 =
                 Setup.run(["--web", "--no-service"],
                   standalone?: fn -> true end,
                   display?: fn -> true end
                 )
      end)

    assert stderr =~ "--web and --no-service are mutually exclusive"
  end

  test "supervision_required?/1 keeps web setup out of the local runtime" do
    refute Setup.supervision_required?([],
             standalone?: fn -> true end,
             display?: fn -> true end
           )

    assert Setup.supervision_required?([],
             standalone?: fn -> true end,
             display?: fn -> false end
           )

    refute Setup.supervision_required?(["--web"],
             standalone?: fn -> true end,
             display?: fn -> false end
           )

    refute Setup.supervision_required?(["--web"], standalone?: fn -> true end)

    assert Setup.supervision_required?(["--cli"], standalone?: fn -> true end)
    assert Setup.supervision_required?(["--terminal"], standalone?: fn -> true end)
    assert Setup.supervision_required?(["--no-service"], standalone?: fn -> true end)
    assert Setup.supervision_required?(["--provider", "openai"], standalone?: fn -> true end)
  end

  defp runtime(parent) do
    fn opts, _io_opts ->
      send(parent, {:runtime, opts})
      :ok
    end
  end

  defp unexpected_runtime(parent) do
    fn opts, _io_opts ->
      send(parent, {:runtime, opts})
      {:error, "unexpected runtime"}
    end
  end

  defp unexpected_web_launcher(parent) do
    fn opts ->
      send(parent, {:web_launcher, opts})
      {:error, "unexpected web launcher"}
    end
  end

  defp fake_service(parent, opts) do
    installed? = Keyword.fetch!(opts, :installed?)
    drifted? = Keyword.get(opts, :drifted?, false)

    %{
      installed?: fn scope, service_opts ->
        send(parent, {:service, :installed?, scope, service_opts})
        installed?
      end,
      drifted?: fn scope, service_opts ->
        send(parent, {:service, :drifted?, scope, service_opts})
        drifted?
      end,
      install: fn scope, service_opts ->
        send(parent, {:service, :install, scope, service_opts})
        :ok
      end,
      start: fn scope, service_opts ->
        send(parent, {:service, :start, scope, service_opts})
        :ok
      end,
      restart: fn scope, service_opts ->
        send(parent, {:service, :restart, scope, service_opts})
        :ok
      end
    }
  end
end
