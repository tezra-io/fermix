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

  alias FermixCore.Transcription.ChunkedStream
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
      {:ok, {_name, module}} -> module.transcribe(path, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Opens a live transcription stream and returns the session process.

  Resolves the active backend, then dispatches on its DECLARED capability — not
  on a runtime attempt: `streaming?: true` gets `backend.open_stream/2`,
  `streaming?: false` gets the `FermixCore.Transcription.ChunkedStream` adapter
  wrapping `backend.transcribe/2`. `opts[:backend]` is the same DI seam as
  `transcribe/2`; every other opt is forwarded to the session unchanged, so a
  caller's `:session_id` correlation rides each provider span.

  The backend's `configured?/1` preflight runs BEFORE any process starts: an
  unconfigured backend is a synchronous `{:error, reason}` here rather than a
  session that dies a moment after being handed out. The session's message
  contract is `FermixCore.Transcription.StreamSession`.
  """
  @spec open_stream(pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open_stream(consumer, opts \\ []) when is_pid(consumer) and is_list(opts) do
    with {:ok, {_name, module}} <- resolve_backend(opts),
         :ok <- module.configured?(opts) do
      start_session(module, consumer, opts)
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

  defp start_session(module, consumer, opts) do
    case module.capabilities() do
      %{streaming?: true} -> module.open_stream(consumer, opts)
      %{streaming?: false} -> ChunkedStream.open(consumer, module, opts)
    end
  end

  defp resolve_backend(opts) do
    case Keyword.get(opts, :backend) do
      nil -> active_backend()
      module when is_atom(module) -> {:ok, {module.name(), module}}
    end
  end
end
