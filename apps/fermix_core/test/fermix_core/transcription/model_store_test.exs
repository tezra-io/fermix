defmodule FermixCore.Transcription.Local.ModelStoreTest do
  # async: false — every test repoints FERMIX_HOME, which is global.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription.Local.ModelStore

  @engine "fake-engine"
  @model "fake-model"

  @encoder "encoder-bytes\n"
  @tokens "tokens-bytes\n"

  setup do
    prev_home = System.get_env("FERMIX_HOME")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-stt-models")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case prev_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf(home)
    end)

    {:ok, _agent} = Agent.start_link(fn -> [] end, name: :stt_model_store_requests)
    %{home: home}
  end

  # A plug that serves each file by its path and records every request, so an
  # idempotent re-install can be proven to make no requests at all.
  def serve(%Plug.Conn{} = conn) do
    Agent.update(agent(), &[conn.request_path | &1])

    case conn.request_path do
      "/encoder.onnx" -> Plug.Conn.send_resp(conn, 200, @encoder)
      "/tokens.txt" -> Plug.Conn.send_resp(conn, 200, @tokens)
      _other -> Plug.Conn.send_resp(conn, 404, "no such file")
    end
  end

  describe "the baked catalog" do
    test "carries minted pins, and the unpinned gate still refuses through the seam" do
      assert ModelStore.pins_pinned?()

      # The shipped pins are minted now, so the defensive unpinned-model refusal is
      # only reachable through the `sha256_pinned: false` seam — which returns
      # before any download, on any host.
      assert ModelStore.install("sherpa-onnx", "parakeet-tdt-0.6b-v3-int8", sha256_pinned: false) ==
               {:error, :model_pins_missing}
    end

    test "carries the operator copy doctor and setup render verbatim" do
      message = ModelStore.error_message(:model_pins_missing)

      assert message =~ "no sha256 pins in this fermix build yet"
      assert message =~ "first fermix-stt release"
      assert message =~ "FERMIX_HOME/models/stt/<engine>/<model>/"
    end

    test "names the files the shipped model consists of" do
      assert {:ok, names} = ModelStore.file_names("sherpa-onnx", "parakeet-tdt-0.6b-v3-int8")
      assert "tokens.txt" in names
      assert Enum.any?(names, &String.ends_with?(&1, ".onnx"))
    end

    test "an unknown model fails loud rather than inventing a directory" do
      assert ModelStore.file_names("sherpa-onnx", "whisper-large") ==
               {:error, {:unknown_model, "sherpa-onnx", "whisper-large"}}

      assert ModelStore.install("sherpa-onnx", "whisper-large", catalog: catalog()) ==
               {:error, {:unknown_model, "sherpa-onnx", "whisper-large"}}
    end
  end

  describe "install/3 through the catalog seam" do
    test "downloads, verifies, and moves the whole model into place", %{home: home} do
      assert ModelStore.install(@engine, @model, catalog: catalog(), req_options: req_options()) ==
               :ok

      dir = Path.join([home, "models", "stt", @engine, @model])
      assert File.read!(Path.join(dir, "encoder.onnx")) == @encoder
      assert File.read!(Path.join(dir, "tokens.txt")) == @tokens
    end

    test "leaves no staging directory behind", %{home: home} do
      assert :ok =
               ModelStore.install(@engine, @model, catalog: catalog(), req_options: req_options())

      assert staging_dirs(home) == []
    end

    test "reports download and verify progress per file" do
      me = self()

      assert :ok =
               ModelStore.install(@engine, @model,
                 catalog: catalog(),
                 req_options: req_options(),
                 progress: fn event -> send(me, {:progress, event}) end
               )

      assert_received {:progress, {:model, :downloading}}
      assert_received {:progress, {:model, :verifying}}
    end

    test "a checksum mismatch fails loud and installs nothing", %{home: home} do
      wrong = String.duplicate("0", 64)

      assert {:error, {:sha256_mismatch, expected: ^wrong, actual: actual}} =
               ModelStore.install(@engine, @model,
                 catalog: catalog(sha256: wrong),
                 req_options: req_options()
               )

      assert actual == sha256(@encoder)
      refute File.dir?(Path.join([home, "models", "stt", @engine, @model]))
      assert staging_dirs(home) == []
    end

    test "a re-install of a present model makes no requests" do
      assert :ok =
               ModelStore.install(@engine, @model, catalog: catalog(), req_options: req_options())

      requested = Agent.get(agent(), & &1)
      assert length(requested) == 2

      assert :ok =
               ModelStore.install(@engine, @model, catalog: catalog(), req_options: req_options())

      assert Agent.get(agent(), & &1) == requested
    end

    test "the baked catalog installs once its pins exist" do
      assert ModelStore.install(@engine, @model,
               sha256_pinned: true,
               catalog: catalog(),
               req_options: req_options()
             ) == :ok
    end
  end

  describe "installed?/2 and model_dir/2" do
    test "both are false/error until every file of the model is present", %{home: home} do
      dir = Path.join([home, "models", "stt", @engine, @model])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "encoder.onnx"), @encoder)

      refute ModelStore.installed?("sherpa-onnx", "parakeet-tdt-0.6b-v3-int8")
      assert ModelStore.model_dir(@engine, @model) == {:error, :model_not_installed}
    end

    test "the model root hangs off the fermix home, not the OS cache", %{home: home} do
      assert ModelStore.model_root() == Path.join([home, "models", "stt"])
    end

    test "the shipped model resolves once its files exist on disk", %{home: home} do
      {:ok, names} = ModelStore.file_names("sherpa-onnx", "parakeet-tdt-0.6b-v3-int8")
      dir = Path.join([home, "models", "stt", "sherpa-onnx", "parakeet-tdt-0.6b-v3-int8"])
      File.mkdir_p!(dir)
      Enum.each(names, &File.write!(Path.join(dir, &1), "x"))

      assert ModelStore.installed?("sherpa-onnx", "parakeet-tdt-0.6b-v3-int8")
      assert ModelStore.model_dir("sherpa-onnx", "parakeet-tdt-0.6b-v3-int8") == {:ok, dir}
    end
  end

  defp catalog(overrides \\ []) do
    %{
      {@engine, @model} => [
        %{
          name: "encoder.onnx",
          url: "http://models.test/encoder.onnx",
          sha256: Keyword.get(overrides, :sha256, sha256(@encoder))
        },
        %{name: "tokens.txt", url: "http://models.test/tokens.txt", sha256: sha256(@tokens)}
      ]
    }
  end

  defp req_options, do: [plug: &__MODULE__.serve/1]

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp staging_dirs(home) do
    [home, "models", "stt"]
    |> Path.join()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".staging-"))
  end

  defp agent, do: :stt_model_store_requests
end
