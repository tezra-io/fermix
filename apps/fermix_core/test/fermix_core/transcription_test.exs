defmodule FermixCore.TranscriptionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Transcription

  defmodule FakeBackend do
    def transcribe(path, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:engine_transcribe, path, opts})
      {:ok, "engine transcript"}
    end
  end

  test "transcribe/2 dispatches to the backend supplied in opts" do
    assert {:ok, "engine transcript"} =
             Transcription.transcribe("/tmp/clip.ogg", backend: FakeBackend, test_pid: self())

    assert_receive {:engine_transcribe, "/tmp/clip.ogg", opts}
    assert Keyword.fetch!(opts, :backend) == FakeBackend
  end

  test "default_backend/0 returns a loadable backend module" do
    backend = Transcription.default_backend()

    assert is_atom(backend)
    assert Code.ensure_loaded?(backend)
  end
end
