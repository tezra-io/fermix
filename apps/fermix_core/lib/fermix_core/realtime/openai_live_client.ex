defmodule FermixCore.Realtime.OpenAILiveClient do
  @moduledoc """
  WebSocket client and event mapping for the OpenAI Live voice API.

  The peer is verified against the OS trust store via `FermixCore.Net.Tls` — the
  account's bearer token travels in the handshake headers, so an unverified
  socket would hand it to whoever answered. `WebSockex` defaults to
  `insecure: true`, so this is not optional.

  The Live wire is deliberately narrow, and this module is the only place that
  knows it:

    * `Authorization` is the ONLY header. There is no `OpenAI-Beta` on Live and
      the safety-identifier header is undocumented for it, so neither is sent.
    * Nothing but `session.start` may be sent until `session.started` arrives,
      and model, voice, instructions, format and delegation mode are immutable
      afterwards. There is no `session.update`, no `response.create` and no
      `conversation.item.create` on this wire — a Realtime habit sent here is a
      protocol error, not a no-op.
    * `delegation_id` is PRESENT on every append; `null` is a value meaning
      "general context", and omitting the key is not the same thing.
    * Audio appends are the one event with no acknowledgement. Every other
      client event carries an `event_id` that the server echoes as
      `client_event_id`, which is how an append is correlated with its ack.

  Decoded events reach the parent as `{:openai_live_event, decoded}`, transport
  loss as `{:openai_live_disconnect, status}`, and a frame that could not be
  read as `{:openai_live_error, reason}`.
  """

  use WebSockex

  alias FermixCore.Net.Tls
  alias FermixCore.Realtime.Config

  @url "wss://api.openai.com/v1/live/sessions"
  @handshake_timeout_ms 5_000
  @audio_rate 24_000

  @spec handshake_timeout_ms() :: pos_integer()
  def handshake_timeout_ms, do: @handshake_timeout_ms

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.fetch!(opts, :headers)
    parent = Keyword.fetch!(opts, :parent)

    with {:ok, start_opts} <- start_options(url, headers) do
      WebSockex.start_link(url, __MODULE__, %{parent: parent}, start_opts)
    end
  end

  @doc """
  The `WebSockex` options for `url`, or `{:error, :ws_url_without_host}` when
  the URL names no host.

  The URL is a vendor constant, so the refusal is unreachable in production — it
  exists so there is exactly one way a socket in this repo acquires its TLS
  options, and no path that dials under WebSockex's `verify_none` default.
  """
  @spec start_options(String.t(), [{String.t(), String.t()}]) ::
          {:ok, keyword()} | {:error, :ws_url_without_host}
  def start_options(url, headers) when is_binary(url) and is_list(headers) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        {:ok,
         [
           extra_headers: headers,
           handshake_timeout: @handshake_timeout_ms,
           ssl_options: Tls.client_options(host)
         ]}

      %URI{} ->
        {:error, :ws_url_without_host}
    end
  end

  @spec send_event(pid(), map()) :: :ok | {:error, term()}
  def send_event(pid, event) when is_pid(pid) and is_map(event) do
    with {:ok, payload} <- Jason.encode(event) do
      WebSockex.send_frame(pid, {:text, payload})
    end
  end

  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid), do: WebSockex.cast(pid, :close)

  @doc "The Live sessions endpoint. No query string: the model rides in `session.start`."
  @spec url() :: String.t()
  def url, do: @url

  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(api_key) when is_binary(api_key) and api_key != "" do
    [{"Authorization", "Bearer #{api_key}"}]
  end

  @doc "A fresh client event id, unique for the life of this node."
  @spec new_event_id() :: String.t()
  def new_event_id do
    "ev_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  @doc """
  The one event that opens a Live session.

  `store: false` is explicit: provider-side recording is a separate feature and
  must never follow from local transcripts being enabled.
  """
  @spec session_start_event(Config.t(), String.t(), keyword()) :: map()
  def session_start_event(%Config{} = config, instructions, opts)
      when is_binary(instructions) and is_list(opts) do
    session = %{
      model: config.model,
      instructions: instructions,
      audio: %{
        format: %{type: "audio/pcm", rate: @audio_rate},
        output: %{voice: config.voice}
      },
      delegation: %{type: "client"},
      store: false
    }

    case Keyword.get(opts, :event_id) do
      nil -> %{type: "session.start", session: session}
      event_id -> %{type: "session.start", event_id: event_id, session: session}
    end
  end

  @doc """
  One microphone chunk. No event id: Live never acknowledges audio.

  PCM16 samples are two bytes, so an odd-length chunk is a corrupted frame and
  is refused here rather than shifted onto the provider's decoder.
  """
  @spec audio_append_event(binary()) :: map()
  def audio_append_event(audio) when is_binary(audio) and rem(byte_size(audio), 2) == 0 do
    %{type: "session.input_audio.append", audio: Base.encode64(audio)}
  end

  @spec mute_event(String.t(), boolean()) :: map()
  def mute_event(event_id, true) when is_binary(event_id),
    do: %{type: "session.input_audio.mute", event_id: event_id}

  def mute_event(event_id, false) when is_binary(event_id),
    do: %{type: "session.input_audio.unmute", event_id: event_id}

  @doc """
  General context for the voice model, not attached to any task.

  `delegation_id` is `nil` here and that is a VALUE on this wire, encoded as
  JSON `null`.
  """
  @spec instructions_append_event(String.t(), nil, String.t()) :: {String.t(), map()}
  def instructions_append_event(event_id, nil, content)
      when is_binary(event_id) and is_binary(content) do
    {event_id, append_event("session.instructions.append", event_id, nil, content)}
  end

  @doc "Bounded progress for one delegation: what the backend is doing right now."
  @spec thinking_append_event(String.t(), String.t(), String.t()) :: {String.t(), map()}
  def thinking_append_event(event_id, delegation_id, content)
      when is_binary(event_id) and is_binary(delegation_id) and is_binary(content) do
    {event_id, append_event("session.thinking.append", event_id, delegation_id, content)}
  end

  @doc "A delegation result worth speaking aloud."
  @spec commentary_append_event(String.t(), String.t(), String.t()) :: {String.t(), map()}
  def commentary_append_event(event_id, delegation_id, content)
      when is_binary(event_id) and is_binary(delegation_id) and is_binary(content) do
    {event_id, append_event("session.commentary.append", event_id, delegation_id, content)}
  end

  @spec close_event(String.t()) :: map()
  def close_event(event_id) when is_binary(event_id) do
    %{type: "session.close", event_id: event_id}
  end

  @doc """
  Map one server frame to a tagged tuple.

  Unknown and merely-reflected types decode as `{:unhandled, type, event}`: the
  Live wire adds families (`transport.*`, `response.event`) that carry nothing a
  session acts on, and refusing them would turn a vendor addition into a broken
  call.
  """
  @spec decode_server_event(map()) :: {:ok, tuple()} | {:error, term()}
  def decode_server_event(%{"type" => "session.started", "session" => %{"id" => id} = session})
      when is_binary(id) do
    {:ok, {:session_started, %{id: id, expires_at: Map.get(session, "expires_at")}}}
  end

  def decode_server_event(%{"type" => "session.updated"} = event) do
    {:ok, {:session_updated, event}}
  end

  def decode_server_event(%{"type" => "session.input_audio.muted"}),
    do: {:ok, {:input_muted, true}}

  def decode_server_event(%{"type" => "session.input_audio.unmuted"}),
    do: {:ok, {:input_muted, false}}

  def decode_server_event(%{"type" => "session.instructions.appended"} = event),
    do: {:ok, {:append_acked, :instructions, Map.get(event, "client_event_id")}}

  def decode_server_event(%{"type" => "session.thinking.appended"} = event),
    do: {:ok, {:append_acked, :thinking, Map.get(event, "client_event_id")}}

  def decode_server_event(%{"type" => "session.commentary.appended"} = event),
    do: {:ok, {:append_acked, :commentary, Map.get(event, "client_event_id")}}

  # `start_ms`/`end_ms` are absent on the primary socket and present on a
  # sideband one. Neither is required to play audio, so both shapes decode the
  # same way rather than one of them being dropped as malformed.
  def decode_server_event(%{"type" => "session.output_audio.delta", "delta" => delta})
      when is_binary(delta) do
    {:ok, {:audio_delta, delta}}
  end

  def decode_server_event(%{"type" => "session.input_transcript.delta"} = event) do
    transcript_delta(:user, event)
  end

  def decode_server_event(%{"type" => "session.output_transcript.delta"} = event) do
    transcript_delta(:assistant, event)
  end

  def decode_server_event(
        %{
          "type" => "session.delegation.created",
          "delegation" => %{"id" => id, "target" => "client"}
        } = event
      )
      when is_binary(id) do
    {:ok, {:delegation_created, id, offset_ms(event)}}
  end

  # Cumulative, never a delta: the session replaces its total with this number.
  def decode_server_event(%{
        "type" => "session.usage.updated",
        "usage" => %{"seconds" => seconds}
      })
      when is_number(seconds) do
    {:ok, {:usage_updated, seconds}}
  end

  def decode_server_event(%{"type" => "session.closed", "reason" => reason} = event)
      when is_binary(reason) do
    {:ok, {:session_closed, reason, closed_seconds(event)}}
  end

  def decode_server_event(%{"type" => "error", "error" => error}) when is_map(error) do
    {:ok, {:error, error}}
  end

  def decode_server_event(%{"type" => "info"} = event) do
    {:ok, {:info, Map.get(event, "code"), Map.get(event, "message")}}
  end

  def decode_server_event(%{"type" => type} = event) when is_binary(type) do
    {:ok, {:unhandled, type, event}}
  end

  def decode_server_event(other), do: {:error, {:invalid_server_event, other}}

  @impl true
  def handle_frame({:text, payload}, state) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = event} ->
        notify_parent(state.parent, event)
        {:ok, state}

      {:error, reason} ->
        send(state.parent, {:openai_live_error, {:decode_failed, Exception.message(reason)}})
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_disconnect(status, state) do
    send(state.parent, {:openai_live_disconnect, status})
    {:ok, state}
  end

  defp append_event(type, event_id, delegation_id, content) do
    %{type: type, event_id: event_id, delegation_id: delegation_id, content: content}
  end

  defp transcript_delta(speaker, %{"delta" => delta} = event) when is_binary(delta) do
    {:ok, {:transcript_delta, speaker, delta, offset(event, "start_ms"), offset(event, "end_ms")}}
  end

  defp transcript_delta(_speaker, event), do: {:ok, {:unhandled, event["type"], event}}

  defp offset(event, key) do
    case Map.get(event, key) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp offset_ms(event), do: offset(event, "offset_ms")

  defp closed_seconds(%{"usage" => %{"seconds" => seconds}}) when is_number(seconds), do: seconds
  defp closed_seconds(_event), do: nil

  defp notify_parent(parent, event) do
    case decode_server_event(event) do
      {:ok, decoded} -> send(parent, {:openai_live_event, decoded})
      {:error, reason} -> send(parent, {:openai_live_error, reason})
    end
  end
end
