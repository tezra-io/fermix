defmodule FermixCore.Transcription.Local do
  @moduledoc """
  On-device transcription backend: the `fermix-stt` sidecar running
  sherpa-onnx over a locally installed Parakeet checkpoint. Audio never leaves
  the machine, and there is no key to configure — what it needs instead is an
  installed binary and an installed model.

  Both halves are explicit. `configured?/1` reports which one is missing as its
  own error (`:sidecar_not_installed` / `:model_not_installed`) so doctor and the
  setup card can each print the one sentence that fixes it, and `transcribe/2`
  fails loud with the same reason rather than degrading to a hosted backend.

  Installing is a deliberate act: `ensure_installed/1` is called by the setup
  surface on enable, and by nothing else. Setting `backend = "local"` in
  `config.toml` by hand installs nothing — it makes every call fail with the
  missing half named. Boot never downloads.

  Batch and streaming both run on the sidecar: batch spawns a one-shot process
  per call (spawn → hello → transcribe → shutdown), so nothing warm is held
  between voice notes, and a stream owns one sidecar for its lifetime, paying
  the model load once.
  """

  @behaviour FermixCore.Transcription.Backend

  alias FermixCore.Transcription.Local.ModelStore
  alias FermixCore.Transcription.Local.Sidecar
  alias FermixCore.Transcription.Local.SidecarInstaller
  alias FermixCore.Transcription.Local.StreamSession
  alias FermixCore.Transcription.Support

  @engine "sherpa-onnx"
  @model "parakeet-tdt-0.6b-v3-int8"
  @provider :local

  @impl true
  @spec name() :: atom()
  def name, do: @provider

  @impl true
  @spec capabilities() :: FermixCore.Transcription.Backend.capabilities()
  def capabilities, do: %{streaming?: true, local?: true}

  @impl true
  @spec configured?(keyword()) :: :ok | {:error, :sidecar_not_installed | :model_not_installed}
  def configured?(opts) when is_list(opts) do
    with :ok <- sidecar_present(),
         :ok <- model_present() do
      :ok
    end
  end

  @impl true
  @spec transcribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(path, opts \\ []) when is_binary(path) and is_list(opts) do
    case configured?(opts) do
      :ok ->
        Support.with_provider_call(@provider, @model, opts, fn -> Sidecar.batch(path, opts) end)

      {:error, reason} ->
        Support.provider_call_error(@provider, @model, opts, reason)
    end
  end

  @impl true
  @spec open_stream(pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open_stream(consumer, opts) when is_pid(consumer) and is_list(opts) do
    case configured?(opts) do
      :ok -> StreamSession.open(consumer, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Installs the sidecar and the model — the one function the setup surface calls
  on enable. Idempotent: both halves short-circuit when already present.

  `opts[:progress]` is an arity-1 function receiving `{:sidecar | :model, stage}`
  so the card can render progress; `opts[:req_options]` is the test seam
  forwarded to both installers.
  """
  @spec ensure_installed(keyword()) :: :ok | {:error, term()}
  def ensure_installed(opts \\ []) when is_list(opts) do
    progress = Keyword.get(opts, :progress, &noop_progress/1)

    with {:ok, _path} <- install_sidecar(opts, progress),
         :ok <- ModelStore.install(@engine, @model, opts) do
      progress.({:model, :done})
      :ok
    end
  end

  @doc "The engine and model this build runs on-device — the doctor and telemetry identity."
  @spec identity() :: %{engine: String.t(), model: String.t()}
  def identity, do: %{engine: @engine, model: @model}

  defp install_sidecar(opts, progress) do
    case SidecarInstaller.installed?() do
      true -> SidecarInstaller.binary_path()
      false -> download_sidecar(opts, progress)
    end
  end

  defp download_sidecar(opts, progress) do
    progress.({:sidecar, :downloading})

    case SidecarInstaller.install(opts) do
      {:ok, path} ->
        progress.({:sidecar, :done})
        {:ok, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sidecar_present do
    if SidecarInstaller.installed?(), do: :ok, else: {:error, :sidecar_not_installed}
  end

  defp model_present do
    if ModelStore.installed?(@engine, @model), do: :ok, else: {:error, :model_not_installed}
  end

  defp noop_progress(_event), do: :ok
end
