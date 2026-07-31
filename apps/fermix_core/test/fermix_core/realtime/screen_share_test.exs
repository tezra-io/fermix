defmodule FermixCore.Realtime.ScreenShareTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.CaptureHealth
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.ScreenShare

  setup do
    start_supervised!(CaptureHealth)

    computer_use = Application.get_env(:fermix_core, :computer_use, [])
    plugins = Application.get_env(:fermix_core, :plugins)
    home = install_fake_sidecar()

    on_exit(fn ->
      Application.put_env(:fermix_core, :computer_use, computer_use)

      case plugins do
        nil -> Application.delete_env(:fermix_core, :plugins)
        value -> Application.put_env(:fermix_core, :plugins, value)
      end

      if home, do: FermixTestSupport.SafeRm.rm_rf(home)
    end)

    :ok
  end

  # Makes `ComputerUse.ready?/0` true without host state or a download, so the
  # schema assertions below actually run instead of silently taking an
  # "unavailable, nothing to assert" branch. The binary is never executed — these
  # tests only read the advertised schema. `nil` on a host compux ships no artifact
  # for; the schema tests skip explicitly there rather than passing vacuously.
  defp install_fake_sidecar do
    case Compux.Binary.target() do
      {:ok, target} ->
        home =
          Path.join([
            System.tmp_dir!(),
            "fermix-screen-share-schema",
            "home-#{System.unique_integer([:positive])}"
          ])

        binary = Path.join([home, "dev-plugins", "computer_use_sidecar", "bin", target, "compux"])
        File.mkdir_p!(Path.dirname(binary))
        File.write!(binary, "#!/bin/sh\n")
        File.chmod!(binary, 0o755)
        Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))
        home

      {:error, _reason} ->
        nil
    end
  end

  defp schema_or_skip do
    Application.put_env(:fermix_core, :computer_use, enabled: true)

    case ScreenShare.tools(Config.normalize([])) do
      [schema] -> {:ok, schema}
      [] -> :skip
    end
  end

  defp disable_computer_use do
    Application.put_env(:fermix_core, :computer_use, enabled: false)
  end

  test "the verb is not advertised when the operator turned screen sharing off" do
    assert ScreenShare.tools(Config.normalize(screen_share: false)) == []
  end

  # The model must never be able to promise the operator something the daemon
  # will then refuse: no capture backend, no advertised verb.
  test "the verb is not advertised when computer-use cannot capture" do
    disable_computer_use()
    assert ScreenShare.tools(Config.normalize([])) == []
  end

  test "the gate refuses with a typed reason the model can explain" do
    disable_computer_use()

    assert {:error, :screen_share_disabled} =
             ScreenShare.gate(Config.normalize(screen_share: false), :voice)

    assert {:error, :computer_use_unavailable} = ScreenShare.gate(Config.normalize([]), :voice)
  end

  # Screen sharing is host observation, so it inherits computer-use's
  # attended-origin floor: an unattended origin may not start watching a desktop.
  test "an unattended origin may not start watching" do
    Application.put_env(:fermix_core, :computer_use, enabled: true)

    assert {:error, {:host_start_refused, :unattended}} =
             ScreenShare.gate(Config.normalize([]), :unattended)
  end

  test "decode reads the action and defaults the display to the configured one" do
    Application.put_env(:fermix_core, :computer_use, enabled: true, display: 2)

    assert {:ok, :start, 2} = ScreenShare.decode(%{"action" => "start"})
    assert {:ok, :start, 1} = ScreenShare.decode(%{"action" => "start", "display" => 1})
    assert {:ok, :stop, 2} = ScreenShare.decode(%{"action" => "stop"})
  end

  test "decode rejects an unknown action rather than guessing" do
    assert {:error, {:invalid_action, "pause"}} = ScreenShare.decode(%{"action" => "pause"})
    assert {:error, :missing_action} = ScreenShare.decode(%{})

    assert {:error, {:invalid_display, "main"}} =
             ScreenShare.decode(%{"action" => "start", "display" => "main"})
  end

  test "the schema offers exactly start and stop" do
    Application.put_env(:fermix_core, :computer_use, enabled: true)

    case ScreenShare.tools(Config.normalize([])) do
      [] ->
        # No sidecar installed on this machine — the availability rule is covered
        # by the tests above; nothing to assert about the schema here.
        :ok

      [schema] ->
        assert schema.name == "screen_share"
        assert schema.parameters.properties.action.enum == ["start", "stop"]
        assert schema.parameters.required == ["action"]
        # The schema rides every `session.update`, so a narrate-imperative here
        # outlives the once-spoken start text.
        refute schema.description =~ "talk about what you see"
    end
  end

  # The first implicit-trigger wording gated on "only works if you can see their
  # screen", which a shared browser game does NOT meet — one-off `computer_use`
  # screenshots cover it — so the model (defensibly) did not start watching when
  # asked to play together, and the operator had to ask a second time. A later
  # session showed the ask-first framing still lost: a whole shared session ran
  # with no feed while the operator believed one was on. The trigger is the TASK
  # concerning their screen — a shared activity included — never the words
  # "watch my screen", and the model may not imply sight without a running share.
  test "the watch trigger covers a shared activity, not only the impossible-without-it case" do
    case schema_or_skip() do
      :skip ->
        :ok

      {:ok, schema} ->
        refute schema.description =~ "only works if you can see their screen"
        assert schema.description =~ "together"
        assert schema.description =~ "Their task IS the request"
        assert schema.description =~ "do not substitute repeated one-off screenshots"
        assert schema.description =~ "never imply you can see their screen"
    end
  end

  # `started_text/1` was already reworded away from "talk about what you see" — the one
  # spoken once. Nothing may reintroduce it here.
  test "the start text does not ask the model to talk about what it sees" do
    Application.put_env(:fermix_core, :computer_use, enabled: true)

    refute ScreenShare.started_text(0) =~ "talk about what you see"
    assert ScreenShare.started_text(0) =~ "No commentary duty"
  end

  test "every stop reason has operator-facing wording, including unknown ones" do
    for reason <- [
          :requested,
          :cost,
          {:capture_wedged, :grace_expired},
          {:capture_unavailable, :sidecar_missing},
          {:capture_failed, :boom},
          :something_new
        ] do
      assert is_binary(ScreenShare.stopped_text(reason))
    end
  end

  # A failure the model is not told about is worse than the failure: it keeps
  # narrating a screen it can no longer see.
  test "failure wording tells the model to stop claiming it can see" do
    assert ScreenShare.stopped_text({:capture_failed, :boom}) =~ "do not claim you can still see"
    assert ScreenShare.stopped_text({:capture_wedged, :x}) =~ "do not claim you can still see"
  end
end
