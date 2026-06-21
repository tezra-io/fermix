defmodule FermixCore.Tools.Media.Registry do
  @moduledoc """
  Resolves the active media-generation backend module for a `{modality,
  provider}` pair from `[fermix_core.tools.<tool>]` config.

  Mirrors `FermixCore.Tools.WebSearch.active_backend/1`: the active backend is
  the operator's configured choice, looked up in a compile-time map — never a
  runtime default-and-continue. An unknown provider or a missing `backend`
  setting fails loud (Rule #12), because every media backend is keyed and there
  is no keyless degrade path to fall back to.
  """

  alias FermixCore.Config
  alias FermixCore.Tools.Media.Backend
  alias FermixCore.Tools.Media.Backends.GoogleImage
  alias FermixCore.Tools.Media.Backends.OpenAIImage
  alias FermixCore.Tools.Media.Backends.XAIImage

  # Compile-time {modality, provider} -> backend module. No dynamic loading
  # (anti-Hermes). Google video lands in the fast-follow; the {modality,
  # provider} key shape already accommodates `:audio` for the next-release audio
  # modality with no change here.
  @backends %{
    {:image, "openai"} => OpenAIImage,
    {:image, "xai"} => XAIImage,
    {:image, "google"} => GoogleImage
  }

  # Each modality is configured under its agent-facing tool's TOML block, so the
  # backend selection lives beside the rest of that tool's settings.
  @modality_tool %{
    image: :generate_image,
    video: :generate_video
  }

  @doc """
  Resolves the active backend for `modality` from an already-loaded tool config
  keyword (the tool reads `Config.tool/1` once and passes it here).
  """
  @spec active_backend(Backend.modality(), keyword()) :: {:ok, module()} | {:error, String.t()}
  def active_backend(modality, config) when is_atom(modality) and is_list(config) do
    with {:ok, provider} <- configured_provider(modality, config),
         {:ok, module} <- backend_module(modality, provider) do
      {:ok, module}
    end
  end

  @doc """
  Resolves the active backend for `modality`, reading the tool config itself.
  Used where no config is already in hand (e.g. the doctor probe).
  """
  @spec active_backend(Backend.modality()) :: {:ok, module()} | {:error, String.t()}
  def active_backend(modality) when is_atom(modality) do
    with {:ok, tool_key} <- tool_key(modality),
         {:ok, config} <- fetch_config(tool_key) do
      active_backend(modality, config)
    end
  end

  @doc """
  The curated model ids the `{modality, provider}` backend supports (head =
  default). Resolves the backend module the same way `active_backend/2` does, so
  an unknown provider fails loud with the supported set (Rule #12). Used by the
  setup surface to render the model dropdown without touching tool config.
  """
  @spec supported_models(Backend.modality(), String.t() | atom()) ::
          {:ok, [String.t(), ...]} | {:error, String.t()}
  def supported_models(modality, provider) when is_atom(modality) do
    case provider_string(provider) do
      name when is_binary(name) ->
        with {:ok, module} <- backend_module(modality, name), do: {:ok, module.supported_models()}

      nil ->
        {:ok, tool_key} = tool_key(modality)
        {:error, "#{tool_key} has no provider given for supported_models/2."}
    end
  end

  @doc "The TOML tool key that configures `modality` (e.g. `:image -> :generate_image`)."
  @spec tool_key(Backend.modality()) :: {:ok, atom()} | {:error, String.t()}
  def tool_key(modality) when is_atom(modality) do
    case Map.fetch(@modality_tool, modality) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, "Unsupported media modality: #{inspect(modality)}"}
    end
  end

  defp configured_provider(modality, config) do
    case provider_string(Keyword.get(config, :backend)) do
      provider when is_binary(provider) ->
        {:ok, provider}

      nil ->
        {:ok, tool_key} = tool_key(modality)

        {:error,
         "#{tool_key} has no configured backend. Run setup to choose one (#{supported(modality)})."}
    end
  end

  defp provider_string(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp provider_string(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp provider_string(_name), do: nil

  defp backend_module(modality, provider) do
    case Map.fetch(@backends, {modality, provider}) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:ok, tool_key} = tool_key(modality)

        {:error,
         "Unknown #{tool_key} backend #{inspect(provider)}. Supported: #{supported(modality)}."}
    end
  end

  defp fetch_config(tool_key) do
    case Config.tool(tool_key) do
      {:ok, config} ->
        {:ok, config}

      {:error, :not_configured} ->
        {:error,
         "#{tool_key} is not configured. Run setup to choose a backend and set its API key."}
    end
  end

  defp supported(modality) do
    @backends
    |> Map.keys()
    |> Enum.filter(fn {m, _provider} -> m == modality end)
    |> Enum.map(fn {_m, provider} -> provider end)
    |> Enum.sort()
    |> Enum.join(" | ")
  end
end
