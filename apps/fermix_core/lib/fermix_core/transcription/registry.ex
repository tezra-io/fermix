defmodule FermixCore.Transcription.Registry do
  @moduledoc """
  Resolves the active transcription backend module from the configured backend
  name in `[fermix_core.transcription] backend`.

  Mirrors `FermixCore.Tools.Media.Registry`: the active backend is the operator's
  configured choice, looked up in a compile-time name→module map — never a
  runtime default-and-continue. An unknown name (or a missing `backend` setting)
  fails loud (Rule #12); every hosted backend is keyed and there is no keyless
  degrade path. The on-device `local` backend is a real choice, but it ships in a
  later phase of this milestone, so naming it fails loud with that fact rather
  than pretending it exists.
  """

  alias FermixCore.Transcription.Deepgram
  alias FermixCore.Transcription.OpenAI
  alias FermixCore.Transcription.XAI

  # Compile-time backend name -> {name_atom, module}. No dynamic loading. The
  # on-device `local` backend is intentionally absent here (see backend_module/1).
  @backends %{
    "openai" => {:openai, OpenAI},
    "xai" => {:xai, XAI},
    "deepgram" => {:deepgram, Deepgram}
  }

  # Curated model ids the setup surface offers per backend, head = the backend's
  # default (must match each backend module's `@default_model` and the
  # `[fermix_core.transcription]` compile-time default). `model` is a single
  # shared key across backends, so the setup surface resets it to the selected
  # backend's default on a backend switch — otherwise e.g. Deepgram would inherit
  # the OpenAI-shaped default model and 400 (M21 §5.4 coherence caveat). xai is
  # modelless (its endpoint runs a single fixed model and takes no `model`
  # param), represented by an empty list: a KNOWN-modelless backend, distinct from
  # an unknown one — the setup surface hides the model field and never snaps a
  # default for it.
  @models %{
    "openai" => ["gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"],
    "xai" => [],
    "deepgram" => ["nova-3", "nova-2"]
  }

  @doc """
  Resolves the active backend from an already-loaded `[fermix_core.transcription]`
  config keyword. Returns `{name_atom, module}` on success.
  """
  @spec active_backend(keyword()) :: {:ok, {atom(), module()}} | {:error, String.t()}
  def active_backend(config) when is_list(config) do
    with {:ok, name} <- configured_backend(config),
         {:ok, resolved} <- backend_module(name) do
      {:ok, resolved}
    end
  end

  @doc """
  The curated model ids the setup surface offers for `backend` (head = default).
  A modelless backend (xai) returns `{:ok, []}` — a known backend with no
  selectable model, which the setup surface renders as a hidden model field. A
  backend name outside the shipped set fails loud with the supported list — the
  setup UI never asks for `local` or an unknown backend, so a `{:error, _}` here
  is a broken invariant to surface, not degrade.
  """
  @spec supported_models(String.t() | atom()) :: {:ok, [String.t()]} | {:error, String.t()}
  def supported_models(backend) do
    case normalize(backend) do
      name when is_binary(name) -> lookup_models(name)
      nil -> {:error, "transcription has no configured backend. Choose one (#{supported()})."}
    end
  end

  @doc """
  The default model id for `backend` (head of `supported_models/1`). A modelless
  backend (xai) has no default and returns `{:error, :modelless}`, so callers drop
  the shared `model` key rather than snapping a bogus id onto it.
  """
  @spec default_model(String.t() | atom()) ::
          {:ok, String.t()} | {:error, :modelless | String.t()}
  def default_model(backend) do
    case supported_models(backend) do
      {:ok, [default | _rest]} -> {:ok, default}
      {:ok, []} -> {:error, :modelless}
      {:error, _reason} = error -> error
    end
  end

  defp lookup_models(name) do
    case Map.fetch(@models, name) do
      {:ok, models} ->
        {:ok, models}

      :error ->
        {:error, "Unknown transcription backend #{inspect(name)}. Supported: #{supported()}."}
    end
  end

  defp configured_backend(config) do
    case normalize(Keyword.get(config, :backend)) do
      name when is_binary(name) ->
        {:ok, name}

      nil ->
        {:error,
         "transcription has no configured backend. Run `fermix setup` to choose one (#{supported()})."}
    end
  end

  defp backend_module("local") do
    {:error,
     "The on-device transcription backend (fermix-stt) ships in a later phase of this milestone. " <>
       "Supported backends today: #{supported()}."}
  end

  defp backend_module(name) do
    case Map.fetch(@backends, name) do
      {:ok, resolved} ->
        {:ok, resolved}

      :error ->
        {:error, "Unknown transcription backend #{inspect(name)}. Supported: #{supported()}."}
    end
  end

  defp normalize(name) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp normalize(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize(_name), do: nil

  defp supported, do: @backends |> Map.keys() |> Enum.sort() |> Enum.join(" | ")
end
