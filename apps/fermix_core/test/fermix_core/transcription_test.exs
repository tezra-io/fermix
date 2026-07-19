defmodule FermixCore.TranscriptionTest do
  # async: false — the active_backend/0 cases read and mutate the global
  # `:fermix_core, :transcription` app env.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription

  defmodule FakeBackend do
    def transcribe(path, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:engine_transcribe, path, opts})
      {:ok, "engine transcript"}
    end
  end

  setup do
    prior = Application.get_env(:fermix_core, :transcription)

    on_exit(fn ->
      case prior do
        nil -> Application.delete_env(:fermix_core, :transcription)
        value -> Application.put_env(:fermix_core, :transcription, value)
      end
    end)

    :ok
  end

  test "transcribe/2 dispatches to the backend module supplied in opts" do
    assert {:ok, "engine transcript"} =
             Transcription.transcribe("/tmp/clip.ogg", backend: FakeBackend, test_pid: self())

    assert_receive {:engine_transcribe, "/tmp/clip.ogg", opts}
    assert Keyword.fetch!(opts, :backend) == FakeBackend
  end

  test "transcribe/2 fails loud when no backend module is given and the config is unknown" do
    Application.put_env(:fermix_core, :transcription, backend: "midjourney")

    assert {:error, message} = Transcription.transcribe("/tmp/clip.ogg")
    assert message =~ "Unknown transcription backend"
  end

  describe "active_backend/0" do
    test "resolves the configured backend name and module" do
      Application.put_env(:fermix_core, :transcription, backend: "openai")

      assert {:ok, {:openai, FermixCore.Transcription.OpenAI}} = Transcription.active_backend()
    end

    test "accepts an atom backend name" do
      Application.put_env(:fermix_core, :transcription, backend: :xai)

      assert {:ok, {:xai, FermixCore.Transcription.XAI}} = Transcription.active_backend()
    end

    test "fails loud on an unknown backend, listing the supported set" do
      Application.put_env(:fermix_core, :transcription, backend: "midjourney")

      assert {:error, message} = Transcription.active_backend()
      assert message =~ "Unknown transcription backend"
      assert message =~ "deepgram | openai | xai"
    end
  end
end
