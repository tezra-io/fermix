defmodule FermixCore.Transcription.RegistryTest do
  # async: true — Registry.active_backend/1 is pure over the config passed in; it
  # reads no global app env.
  use ExUnit.Case, async: true

  alias FermixCore.Transcription.Deepgram
  alias FermixCore.Transcription.Local
  alias FermixCore.Transcription.OpenAI
  alias FermixCore.Transcription.Registry
  alias FermixCore.Transcription.XAI

  describe "active_backend/1" do
    test "resolves the configured backend from a string name" do
      assert {:ok, {:openai, OpenAI}} = Registry.active_backend(backend: "openai")
      assert {:ok, {:xai, XAI}} = Registry.active_backend(backend: "xai")
      assert {:ok, {:deepgram, Deepgram}} = Registry.active_backend(backend: "deepgram")
      assert {:ok, {:local, Local}} = Registry.active_backend(backend: "local")
    end

    test "resolves an atom backend name" do
      assert {:ok, {:openai, OpenAI}} = Registry.active_backend(backend: :openai)
    end

    test "trims and downcases the backend name" do
      assert {:ok, {:openai, OpenAI}} = Registry.active_backend(backend: "  OpenAI  ")
    end

    test "a missing backend fails loud, never a default-and-continue" do
      assert {:error, message} = Registry.active_backend([])
      assert message =~ "transcription has no configured backend"
      assert message =~ "deepgram | local | openai | xai"
    end

    test "an unknown backend fails loud and lists the supported set" do
      assert {:error, message} = Registry.active_backend(backend: "vosk")
      assert message =~ "Unknown transcription backend"
      assert message =~ "vosk"
      assert message =~ "Supported: deepgram | local | openai | xai"
    end

    test "the on-device backend resolves like any other, key-free" do
      assert {:ok, {:local, Local}} = Registry.active_backend(backend: :local)
      assert {:ok, {:local, Local}} = Registry.active_backend(backend: "  Local  ")
    end
  end

  describe "supported_models/1" do
    test "returns the curated model list per backend, head = default" do
      assert {:ok, ["gpt-4o-mini-transcribe" | _]} = Registry.supported_models("openai")
      assert {:ok, ["nova-3" | _]} = Registry.supported_models("deepgram")
    end

    test "returns an empty list for the modelless xai backend (known, not unknown)" do
      assert {:ok, []} = Registry.supported_models("xai")
      assert {:ok, []} = Registry.supported_models(:xai)
    end

    test "the on-device backend is modelless too — its checkpoint is never a user menu" do
      assert {:ok, []} = Registry.supported_models("local")
      assert {:error, :modelless} = Registry.default_model("local")
    end

    test "offers gpt-transcribe without moving the OpenAI default off the cheap tier" do
      assert {:ok, models} = Registry.supported_models("openai")
      assert "gpt-transcribe" in models
      assert hd(models) == "gpt-4o-mini-transcribe"
    end

    test "accepts atom names and trims/downcases" do
      assert {:ok, ["nova-3" | _]} = Registry.supported_models(:deepgram)
      assert {:ok, ["nova-3" | _]} = Registry.supported_models("  Deepgram ")
    end

    test "fails loud on an unknown backend and lists the supported set" do
      assert {:error, message} = Registry.supported_models("vosk")
      assert message =~ "Unknown transcription backend"
      assert message =~ "deepgram | local | openai | xai"
    end
  end

  describe "backends/0" do
    test "enumerates every shipped backend, on-device included" do
      names = Registry.backends() |> Enum.map(&elem(&1, 0))

      assert names == [:deepgram, :local, :openai, :xai]
      assert {:local, Local} in Registry.backends()
    end
  end

  describe "default_model/1" do
    test "returns the head of the backend's supported models" do
      assert {:ok, "gpt-4o-mini-transcribe"} = Registry.default_model("openai")
      assert {:ok, "nova-3"} = Registry.default_model("deepgram")
    end

    test "returns {:error, :modelless} for the modelless xai backend" do
      assert {:error, :modelless} = Registry.default_model("xai")
    end

    test "fails loud on an unknown backend" do
      assert {:error, message} = Registry.default_model("vosk")
      assert message =~ "Unknown transcription backend"
    end
  end
end
