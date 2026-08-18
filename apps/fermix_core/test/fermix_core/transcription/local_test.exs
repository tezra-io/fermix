defmodule FermixCore.Transcription.LocalTest do
  # async: false — every test repoints FERMIX_HOME and the plugins app env.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription.Local
  alias FermixCore.Transcription.Local.ModelStore
  alias FermixCore.Transcription.Local.SidecarInstaller

  @fake Path.expand("fake_stt_sidecar.pl", __DIR__)

  setup do
    prev_home = System.get_env("FERMIX_HOME")
    prev_plugins = Application.get_env(:fermix_core, :plugins)

    home = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-stt-local")
    System.put_env("FERMIX_HOME", home)
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

  describe "backend metadata" do
    test "declares itself streaming and on-device" do
      assert Local.name() == :local
      assert Local.capabilities() == %{streaming?: true, local?: true}
    end

    test "identity names the engine and checkpoint doctor and telemetry report" do
      assert Local.identity() == %{
               engine: "sherpa-onnx",
               model: "parakeet-tdt-0.6b-v3-int8"
             }
    end
  end

  describe "configured?/1" do
    test "reports a missing sidecar distinctly from a missing model", %{home: home} do
      assert Local.configured?([]) == {:error, :sidecar_not_installed}

      install_sidecar(home)
      assert Local.configured?([]) == {:error, :model_not_installed}

      install_model(home)
      assert Local.configured?([]) == :ok
    end

    test "an incomplete model directory is not configured", %{home: home} do
      install_sidecar(home)
      %{engine: engine, model: model} = Local.identity()
      {:ok, [first | _rest]} = ModelStore.file_names(engine, model)

      dir = Path.join([home, "models", "stt", engine, model])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, first), "x")

      assert Local.configured?([]) == {:error, :model_not_installed}
    end
  end

  describe "transcribe/2" do
    test "fails loud with the missing half named, and never falls back to a hosted backend" do
      assert Local.transcribe("/tmp/note.ogg") == {:error, :sidecar_not_installed}
    end

    test "an unconfigured call still emits an errored provider span" do
      handler = attach_span_handler()
      on_exit(fn -> :telemetry.detach(handler) end)

      assert Local.transcribe("/tmp/note.ogg") == {:error, :sidecar_not_installed}

      assert_receive {:span, _measurements, metadata}
      assert metadata.provider == :local
      assert metadata.model == "parakeet-tdt-0.6b-v3-int8"
      assert metadata.status == :error
      assert metadata.error_code == "provider_error"
    end

    test "runs through the sidecar once both halves are installed", %{home: home} do
      install_sidecar(home)
      install_model(home)
      handler = attach_span_handler()
      on_exit(fn -> :telemetry.detach(handler) end)

      assert Local.transcribe("/tmp/note.ogg", batch_timeout_ms: 2_000) ==
               {:ok, "fake transcript"}

      assert_receive {:span, measurements, metadata}
      assert metadata.provider == :local
      assert metadata.purpose == :transcription
      assert metadata.status == :ok
      assert metadata.tokens == %{}
      assert is_integer(measurements.duration_ms)
    end
  end

  describe "open_stream/2" do
    test "refuses before starting a process when nothing is installed" do
      assert Local.open_stream(self(), []) == {:error, :sidecar_not_installed}
    end
  end

  describe "ensure_installed/1" do
    test "refuses loud while the sidecar has no pinned release" do
      assert Local.ensure_installed() == {:error, :no_release_pinned}
    end

    test "reaches the model step once the sidecar is present", %{home: home} do
      install_sidecar(home)
      me = self()

      assert Local.ensure_installed(progress: fn event -> send(me, {:progress, event}) end) ==
               {:error, :model_pins_missing}

      refute_received {:progress, {:sidecar, :downloading}}
    end

    test "is a no-op on both halves once everything is present", %{home: home} do
      install_sidecar(home)
      install_model(home)

      assert Local.ensure_installed(catalog: fake_catalog()) == :ok
    end
  end

  defp install_sidecar(home) do
    path = Path.join([home, "dev-plugins", "stt_sidecar", "bin", target(), "fermix-stt"])
    File.mkdir_p!(Path.dirname(path))
    File.cp!(@fake, path)
    File.chmod!(path, 0o755)
    Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))
    path
  end

  defp install_model(home) do
    %{engine: engine, model: model} = Local.identity()
    {:ok, names} = ModelStore.file_names(engine, model)
    dir = Path.join([home, "models", "stt", engine, model])
    File.mkdir_p!(dir)
    Enum.each(names, &File.write!(Path.join(dir, &1), "fake-weights"))
    dir
  end

  # The already-installed short circuit runs before any catalog lookup, so an
  # empty catalog proves nothing is downloaded.
  defp fake_catalog do
    %{engine: engine, model: model} = Local.identity()
    {:ok, names} = ModelStore.file_names(engine, model)

    %{
      {engine, model} =>
        Enum.map(names, &%{name: &1, url: "http://models.test/#{&1}", sha256: ""})
    }
  end

  defp target do
    {:ok, target} = SidecarInstaller.target()
    target
  end

  defp attach_span_handler do
    handler = "stt-local-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :provider, :call],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:span, measurements, metadata})
      end,
      nil
    )

    handler
  end
end
