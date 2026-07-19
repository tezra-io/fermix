defmodule FermixCore.Transcription do
  @moduledoc """
  Speech-to-text engine: dispatches an audio file to the configured backend.

  The active backend is resolved from `[fermix_core.transcription] backend` (a
  name string like `"openai"`) through `FermixCore.Transcription.Registry`, which
  fails loud on an unknown name — there is no keyless degrade path.

  Channel-agnostic. The ingress orchestration that decides *when* to transcribe
  an inbound message — detecting an audio attachment, downloading it through the
  channel, and forwarding the transcript — lives in
  `FermixChannels.Gateway.Transcription`.
  """

  alias FermixCore.Transcription.Registry

  @typedoc "A backend name atom and its module, as resolved from config."
  @type active :: {name :: atom(), module :: module()}

  @doc """
  Transcribes `path` through the active backend.

  `opts[:backend]` is a test/DI seam: when present it names the backend module to
  dispatch to directly; otherwise the configured active backend is resolved. Every
  other opt (`:api_key`, `:req_options`, `:metadata`, `:auth_mode`,
  correlation ids) is forwarded to the backend unchanged.
  """
  @spec transcribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(path, opts \\ []) when is_binary(path) do
    case resolve_backend(opts) do
      {:ok, backend} -> backend.transcribe(path, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves the configured active backend as `{name_atom, module}`, or a loud error
  when the `backend` setting is unknown/missing. Exposed for the ingress
  provenance record and (later) `fermix doctor`.
  """
  @spec active_backend() :: {:ok, active()} | {:error, String.t()}
  def active_backend do
    :fermix_core
    |> Application.get_env(:transcription, [])
    |> Registry.active_backend()
  end

  defp resolve_backend(opts) do
    case Keyword.get(opts, :backend) do
      nil ->
        with {:ok, {_name, module}} <- active_backend(), do: {:ok, module}

      module when is_atom(module) ->
        {:ok, module}
    end
  end
end
