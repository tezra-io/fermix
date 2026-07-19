defmodule FermixCore.Tools.Media.RegistryTest do
  # async: false — `active_backend/1` and `fetch_config/1` read the global
  # `:fermix_core, :tools` app env, which the config-reading tests mutate.
  use ExUnit.Case, async: false

  alias FermixCore.Tools.Media.Backends.GoogleImage
  alias FermixCore.Tools.Media.Backends.OpenAIImage
  alias FermixCore.Tools.Media.Backends.XAIImage
  alias FermixCore.Tools.Media.Registry

  setup do
    tools = Application.get_env(:fermix_core, :tools)
    on_exit(fn -> restore(:tools, tools) end)
    :ok
  end

  describe "active_backend/2 (config in hand)" do
    test "resolves the configured backend from a string provider" do
      assert {:ok, OpenAIImage} = Registry.active_backend(:image, backend: "openai")
    end

    test "resolves the configured backend from an atom provider" do
      assert {:ok, OpenAIImage} = Registry.active_backend(:image, backend: :openai)
    end

    test "resolves the xAI image backend" do
      assert {:ok, XAIImage} = Registry.active_backend(:image, backend: "xai")
    end

    test "resolves the Google image backend" do
      assert {:ok, GoogleImage} = Registry.active_backend(:image, backend: "google")
    end

    test "trims and downcases the provider string" do
      assert {:ok, OpenAIImage} = Registry.active_backend(:image, backend: "  OpenAI  ")
    end

    test "missing backend fails loud, never a default-and-continue" do
      assert {:error, message} = Registry.active_backend(:image, [])
      assert message =~ "generate_image has no configured backend"
      assert message =~ "openai"
    end

    test "unknown backend fails loud and lists the supported set" do
      assert {:error, message} = Registry.active_backend(:image, backend: "midjourney")
      assert message =~ "Unknown generate_image backend"
      assert message =~ "midjourney"
      # All wired image providers are offered, sorted.
      assert message =~ "Supported: google | openai | openai_codex | xai"
    end

    test "a modality with no backend wired yet fails loud" do
      assert {:error, message} = Registry.active_backend(:video, backend: "openai")
      assert message =~ "Unknown generate_video backend"
    end
  end

  describe "active_backend/1 (reads tool config)" do
    test "reads the tool block and resolves the backend" do
      Application.put_env(:fermix_core, :tools, generate_image: [backend: "openai"])
      assert {:ok, OpenAIImage} = Registry.active_backend(:image)
    end

    test "an unconfigured tool block fails loud" do
      Application.put_env(:fermix_core, :tools, [])
      assert {:error, message} = Registry.active_backend(:image)
      assert message =~ "generate_image is not configured"
    end
  end

  describe "supported_models/2" do
    test "returns the OpenAI image models, default first" do
      assert {:ok, ["gpt-image-2", "gpt-image-1.5"]} =
               Registry.supported_models(:image, "openai")
    end

    test "returns the xAI image model" do
      assert {:ok, ["grok-imagine-image-quality"]} = Registry.supported_models(:image, "xai")
    end

    test "returns the Google image models, default first" do
      assert {:ok, ["gemini-3.1-flash-image", "gemini-3-pro-image", "gemini-2.5-flash-image"]} =
               Registry.supported_models(:image, "google")
    end

    test "accepts an atom provider and normalizes a messy string" do
      assert {:ok, ["gpt-image-2" | _rest]} = Registry.supported_models(:image, :openai)
      assert {:ok, ["gpt-image-2" | _rest]} = Registry.supported_models(:image, "  OpenAI  ")
    end

    test "an unknown backend fails loud and lists the supported set" do
      assert {:error, message} = Registry.supported_models(:image, "midjourney")
      assert message =~ "Unknown generate_image backend"
      assert message =~ "Supported: google | openai | openai_codex | xai"
    end

    test "a missing provider fails loud" do
      assert {:error, message} = Registry.supported_models(:image, nil)
      assert message =~ "no provider given"
    end
  end

  describe "tool_key/1" do
    test "maps a modality to its agent-facing tool key" do
      assert {:ok, :generate_image} = Registry.tool_key(:image)
      assert {:ok, :generate_video} = Registry.tool_key(:video)
    end

    test "an unsupported modality fails loud" do
      assert {:error, message} = Registry.tool_key(:audio)
      assert message =~ "Unsupported media modality"
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
