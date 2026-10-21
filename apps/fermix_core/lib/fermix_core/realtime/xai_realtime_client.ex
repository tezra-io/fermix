defmodule FermixCore.Realtime.XAIRealtimeClient do
  @moduledoc """
  WebSocket client and event mapping for the SpaceXAI (Grok) voice agent API.

  The peer is verified against the OS trust store via `FermixCore.Net.Tls` — the
  account's API key travels in the handshake headers, so an unverified socket
  would hand it to whoever answered.

  Every event and error this process sends its parent names the socket
  (`self()`), because a session outlives its sockets and must tell the current
  one from one it closed. A socket's death reaches the parent only as its
  `EXIT`, through the link `start_link/1` makes: there is no disconnect notice,
  so one death is one signal.

  The wire resembles OpenAI Realtime but is not it, so nothing here is shared
  with `OpenAIClient`:

    * The model rides the URL. `session.update` carries no model, no hosted
      tools (`web_search`, `x_search`, MCP) and no `idle_timeout_ms`, so the
      vendor never searches on its own or speaks unprompted into a silence.
    * Resumption is off: a lost connection ends the call rather than replaying
      turns from a vendor cache.
    * Audio is JSON/base64 in both directions. A binary frame means the vendor
      switched transport under us, and is reported, never guessed at.

  Decoding is strict. A known event missing a field the session acts on is a
  protocol error naming the event and the field, not an invitation to guess at
  another shape; an event the session has no use for decodes as `{:unhandled,
  type}` so a vendor addition never breaks a call. Frames are bounded before
  they are parsed, and a vendor error reaches the session as bounded text.
  """

  use WebSockex

  alias FermixCore.Net.Egress
  alias FermixCore.Net.Tls
  alias FermixCore.Realtime.Config
  alias FermixCore.Text

  @base_url "wss://api.x.ai/v1/realtime"
  @handshake_timeout_ms 5_000
  @audio_rate 24_000

  # The largest text frame this socket will parse. An audio delta is a fraction
  # of this; anything larger is a fault, and parsing it would put megabytes of
  # JSON on the call's critical path.
  @max_frame_bytes 1_048_576

  # A vendor error's words travel to the trace and the companion, so each field
  # is cut to a bound rather than carried whole.
  @max_error_field_bytes 500

  # The vendor caps a metadata value at 512 characters.
  @max_continuation_bytes 512

  @context_roles ~w(system user assistant)
  @audio_delta_types ["response.output_audio.delta", "response.audio.delta"]

  @type item_added :: %{id: String.t(), type: String.t(), role: String.t() | nil}

  @type function_call :: %{
          response_id: String.t(),
          item_id: String.t(),
          call_id: String.t(),
          name: String.t(),
          arguments: String.t()
        }

  @type vendor_error :: %{
          type: String.t() | nil,
          code: String.t() | nil,
          message: String.t() | nil,
          param: String.t() | nil
        }

  @type server_event ::
          {:session_created, String.t()}
          | {:conversation_created, String.t()}
          | {:session_updated, %{turn_detection: String.t() | nil, voice: String.t() | nil}}
          | {:speech_started, String.t()}
          | {:speech_stopped, String.t()}
          | {:item_added, item_added()}
          | {:user_transcript, String.t(), String.t()}
          | {:item_truncated, String.t(), String.t() | nil}
          | {:response_created, String.t(), map() | nil}
          | {:audio_delta, String.t(), String.t(), non_neg_integer(), String.t()}
          | {:assistant_transcript_delta, String.t(), String.t(), String.t()}
          | {:assistant_transcript_done, String.t(), String.t()}
          | {:function_call, function_call()}
          | {:response_done, String.t(), String.t(), map() | nil}
          | {:error, vendor_error()}
          | {:unhandled, String.t()}

  @spec handshake_timeout_ms() :: pos_integer()
  def handshake_timeout_ms, do: @handshake_timeout_ms

  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    url = Keyword.fetch!(opts, :url)
    headers = Keyword.fetch!(opts, :headers)
    parent = Keyword.fetch!(opts, :parent)
    egress = Keyword.get_lazy(opts, :egress, &Egress.active/0)

    # This socket cannot tunnel, so behind a proxy it refuses rather than dial
    # around it.
    with :ok <- Egress.ensure_direct(url, egress),
         {:ok, start_opts} <- start_options(url, headers) do
      WebSockex.start_link(url, __MODULE__, %{parent: parent}, start_opts)
    end
  end

  @doc """
  The `WebSockex` options for `url`, or `{:error, :ws_url_without_host}` when
  the URL names no host.

  `url/1` builds a vendor constant, so the refusal is unreachable in production
  — the URL is parsed for its host anyway so there is one way a socket in this
  repo acquires its TLS options, and no path that dials under WebSockex's
  `verify_none` default.
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

  @doc "The voice agent endpoint for `model`, which rides the query string."
  @spec url(String.t()) :: String.t()
  def url(model) when is_binary(model) and model != "" do
    @base_url <> "?model=" <> URI.encode_www_form(model)
  end

  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(api_key) when is_binary(api_key) and api_key != "" do
    [{"Authorization", "Bearer " <> api_key}]
  end

  @doc """
  A fresh client item id, unique for the life of this node. Context items carry
  one so their `conversation.item.added` acknowledgement can be matched to the
  item that was sent.
  """
  @spec new_item_id() :: String.t()
  def new_item_id do
    "fx_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  @doc """
  The one configuration a Grok call sends.

  Reasoning is pinned to `high` until `none` is qualified separately. Turn
  detection is plain server VAD with no `idle_timeout_ms`: an idle timer makes
  the vendor start check-in turns of its own, which this design leaves out.
  """
  @spec session_update_event(Config.t(), String.t(), [map()]) :: map()
  def session_update_event(%Config{engine: "xai_realtime", voice: voice}, instructions, tools)
      when is_binary(voice) and is_binary(instructions) and is_list(tools) do
    %{
      type: "session.update",
      session: %{
        instructions: instructions,
        voice: voice,
        turn_detection: %{type: "server_vad"},
        reasoning: %{effort: "high"},
        resumption: %{enabled: false},
        tools: tools,
        audio: %{
          input: %{format: pcm_format()},
          output: %{format: pcm_format()}
        }
      }
    }
  end

  @doc """
  One microphone chunk.

  PCM16 samples are two bytes, so an odd-length chunk is a corrupted frame and
  is refused here rather than shifted onto the provider's decoder.
  """
  @spec audio_append_event(binary()) :: map()
  def audio_append_event(pcm) when is_binary(pcm) and rem(byte_size(pcm), 2) == 0 do
    %{type: "input_audio_buffer.append", audio: Base.encode64(pcm)}
  end

  @doc """
  A text item of conversation context under a client-chosen id.

  The vendor's schema takes `input_text` parts for system and user messages and
  `text` for the assistant's own earlier words, so the part type follows the
  role.
  """
  @spec context_item_event(String.t(), String.t(), String.t()) :: map()
  def context_item_event(item_id, role, text)
      when is_binary(item_id) and item_id != "" and role in @context_roles and is_binary(text) do
    %{
      type: "conversation.item.create",
      item: %{
        id: item_id,
        type: "message",
        role: role,
        content: [%{type: part_type(role), text: text}]
      }
    }
  end

  @doc "The answer to one function call, under a client-chosen item id."
  @spec function_output_event(String.t(), String.t(), String.t()) :: map()
  def function_output_event(item_id, call_id, output)
      when is_binary(item_id) and item_id != "" and is_binary(call_id) and call_id != "" and
             is_binary(output) do
    %{
      type: "conversation.item.create",
      item: %{id: item_id, type: "function_call_output", call_id: call_id, output: output}
    }
  end

  @doc """
  Ask for a response, tagged with the continuation it answers.

  The vendor echoes `metadata` on `response.created` and `response.done`, and
  sends `null` there for a response its own VAD started — which is how the
  session tells the answer it asked for from one the caller's speech began.
  """
  @spec response_create_event(String.t()) :: map()
  def response_create_event(continuation_id)
      when is_binary(continuation_id) and continuation_id != "" and
             byte_size(continuation_id) <= @max_continuation_bytes do
    %{type: "response.create", response: %{metadata: %{"fermix_continuation" => continuation_id}}}
  end

  @spec response_cancel_event(String.t()) :: map()
  def response_cancel_event(response_id) when is_binary(response_id) and response_id != "" do
    %{type: "response.cancel", response_id: response_id}
  end

  @doc """
  Cut an assistant item at what the caller actually heard, so the model's
  context holds no words that never played.
  """
  @spec truncate_event(String.t(), non_neg_integer(), non_neg_integer()) :: map()
  def truncate_event(item_id, content_index, audio_end_ms)
      when is_binary(item_id) and item_id != "" and is_integer(content_index) and
             content_index >= 0 and is_integer(audio_end_ms) and audio_end_ms >= 0 do
    %{
      type: "conversation.item.truncate",
      item_id: item_id,
      content_index: content_index,
      audio_end_ms: audio_end_ms
    }
  end

  @doc """
  Map one server frame to a tagged tuple.

  A known type missing a required field is `{:error, {:malformed_event, type,
  field}}`, with `field` the dotted path that was absent or of the wrong type.
  An optional field may be absent or `null` (it decodes as `nil`), but a value
  of the wrong type is still malformed. Every other type is `{:unhandled,
  type}`.
  """
  @spec decode_server_event(map()) :: {:ok, server_event()} | {:error, term()}
  def decode_server_event(%{"type" => type} = event) when is_binary(type), do: decode(type, event)

  def decode_server_event(%{} = event),
    do: {:error, {:invalid_server_event, inspect(event, limit: 5, printable_limit: 120)}}

  defp decode("session.created" = type, event) do
    with {:ok, id} <- id(event, ["session", "id"], type), do: {:ok, {:session_created, id}}
  end

  defp decode("conversation.created" = type, event) do
    with {:ok, id} <- id(event, ["conversation", "id"], type),
         do: {:ok, {:conversation_created, id}}
  end

  defp decode("session.updated" = type, event) do
    with {:ok, _session} <- map(event, ["session"], type),
         {:ok, detection} <- optional_string(event, ["session", "turn_detection", "type"], type),
         {:ok, voice} <- optional_string(event, ["session", "voice"], type) do
      {:ok, {:session_updated, %{turn_detection: detection, voice: voice}}}
    end
  end

  defp decode("input_audio_buffer.speech_started" = type, event) do
    with {:ok, item_id} <- id(event, ["item_id"], type), do: {:ok, {:speech_started, item_id}}
  end

  defp decode("input_audio_buffer.speech_stopped" = type, event) do
    with {:ok, item_id} <- id(event, ["item_id"], type), do: {:ok, {:speech_stopped, item_id}}
  end

  defp decode("conversation.item.added" = type, event) do
    with {:ok, id} <- id(event, ["item", "id"], type),
         {:ok, item_type} <- id(event, ["item", "type"], type),
         {:ok, role} <- optional_string(event, ["item", "role"], type) do
      {:ok, {:item_added, %{id: id, type: item_type, role: role}}}
    end
  end

  defp decode("conversation.item.input_audio_transcription.completed" = type, event) do
    with {:ok, item_id} <- id(event, ["item_id"], type),
         {:ok, transcript} <- string(event, ["transcript"], type) do
      {:ok, {:user_transcript, item_id, transcript}}
    end
  end

  defp decode("conversation.item.truncated" = type, event) do
    with {:ok, item_id} <- id(event, ["item_id"], type),
         {:ok, transcript} <- optional_string(event, ["transcript"], type) do
      {:ok, {:item_truncated, item_id, transcript}}
    end
  end

  defp decode("response.created" = type, event) do
    with {:ok, response_id} <- id(event, ["response", "id"], type),
         {:ok, metadata} <- optional_map(event, ["response", "metadata"], type) do
      {:ok, {:response_created, response_id, metadata}}
    end
  end

  defp decode(type, event) when type in @audio_delta_types do
    with {:ok, response_id} <- id(event, ["response_id"], type),
         {:ok, item_id} <- id(event, ["item_id"], type),
         {:ok, index} <- index(event, ["content_index"], type),
         {:ok, delta} <- string(event, ["delta"], type) do
      {:ok, {:audio_delta, response_id, item_id, index, delta}}
    end
  end

  defp decode("response.output_audio_transcript.delta" = type, event) do
    with {:ok, response_id} <- id(event, ["response_id"], type),
         {:ok, item_id} <- id(event, ["item_id"], type),
         {:ok, delta} <- string(event, ["delta"], type) do
      {:ok, {:assistant_transcript_delta, response_id, item_id, delta}}
    end
  end

  defp decode("response.output_audio_transcript.done" = type, event) do
    with {:ok, response_id} <- id(event, ["response_id"], type),
         {:ok, item_id} <- id(event, ["item_id"], type) do
      {:ok, {:assistant_transcript_done, response_id, item_id}}
    end
  end

  defp decode("response.function_call_arguments.done" = type, event) do
    with {:ok, response_id} <- id(event, ["response_id"], type),
         {:ok, item_id} <- id(event, ["item_id"], type),
         {:ok, call_id} <- id(event, ["call_id"], type),
         {:ok, name} <- id(event, ["name"], type),
         {:ok, arguments} <- string(event, ["arguments"], type) do
      {:ok,
       {:function_call,
        %{
          response_id: response_id,
          item_id: item_id,
          call_id: call_id,
          name: name,
          arguments: arguments
        }}}
    end
  end

  defp decode("response.done" = type, event) do
    with {:ok, response_id} <- id(event, ["response", "id"], type),
         {:ok, status} <- id(event, ["response", "status"], type),
         {:ok, usage} <- optional_map(event, ["response", "usage"], type) do
      {:ok, {:response_done, response_id, status, usage}}
    end
  end

  defp decode("error" = type, event) do
    with {:ok, error} <- map(event, ["error"], type) do
      {:ok,
       {:error,
        %{
          type: error_field(error, "type"),
          code: error_field(error, "code"),
          message: error_field(error, "message"),
          param: error_field(error, "param")
        }}}
    end
  end

  defp decode(type, _event), do: {:ok, {:unhandled, type}}

  # -- field readers -----------------------------------------------------------
  #
  # Each returns `{:ok, value}` or the one malformed-event error, so a decoder
  # clause is a flat `with` over the fields it needs.

  defp id(event, path, type) do
    case dig(event, path) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> malformed(type, path)
    end
  end

  defp string(event, path, type) do
    case dig(event, path) do
      value when is_binary(value) -> {:ok, value}
      _other -> malformed(type, path)
    end
  end

  defp index(event, path, type) do
    case dig(event, path) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> malformed(type, path)
    end
  end

  defp map(event, path, type) do
    case dig(event, path) do
      %{} = value -> {:ok, value}
      _other -> malformed(type, path)
    end
  end

  defp optional_string(event, path, type) do
    case dig(event, path) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> malformed(type, path)
    end
  end

  defp optional_map(event, path, type) do
    case dig(event, path) do
      nil -> {:ok, nil}
      %{} = value -> {:ok, value}
      _other -> malformed(type, path)
    end
  end

  # Not `get_in/2`, which raises when an intermediate value is not a map: a
  # vendor that sends `"turn_detection": "server_vad"` must get a malformed-event
  # error, not a crash in the socket. A path through a non-map ends at
  # `:not_a_map`, which no JSON value can equal.
  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: map |> Map.get(key) |> dig(rest)
  defp dig(nil, _path), do: nil
  defp dig(_other, _path), do: :not_a_map

  defp malformed(type, path), do: {:error, {:malformed_event, type, Enum.join(path, ".")}}

  # The error event is the one frame whose content must reach the operator even
  # when a field is odd, so a non-string field is dropped rather than refusing
  # the whole error.
  defp error_field(error, key) do
    case Map.get(error, key) do
      value when is_binary(value) -> Text.truncate_utf8(value, @max_error_field_bytes)
      _other -> nil
    end
  end

  defp part_type("assistant"), do: "text"
  defp part_type(role) when role in ["system", "user"], do: "input_text"

  defp pcm_format, do: %{type: "audio/pcm", rate: @audio_rate}

  # Valid JSON that is not an object is reported, never matched away: a
  # CaseClauseError here would kill the socket, and with resumption off a dead
  # socket is a dead call. Only a bounded description travels to the session.
  @impl true
  def handle_frame({:text, payload}, state) when byte_size(payload) > @max_frame_bytes do
    send(state.parent, {:xai_realtime_error, self(), {:frame_too_large, byte_size(payload)}})
    {:ok, state}
  end

  def handle_frame({:text, payload}, state) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = event} ->
        notify_parent(state.parent, event)

      {:ok, other} ->
        send(
          state.parent,
          {:xai_realtime_error, self(),
           {:invalid_server_event, inspect(other, limit: 5, printable_limit: 120)}}
        )

      {:error, reason} ->
        send(
          state.parent,
          {:xai_realtime_error, self(), {:decode_failed, Exception.message(reason)}}
        )
    end

    {:ok, state}
  end

  # The session asks for JSON audio, so a binary frame means the transport
  # changed under it. Its bytes are not audio this module knows how to frame.
  def handle_frame({:binary, _data}, state) do
    send(state.parent, {:xai_realtime_error, self(), :unexpected_binary_frame})
    {:ok, state}
  end

  @impl true
  def handle_cast(:close, state), do: {:close, state}

  defp notify_parent(parent, event) do
    case decode_server_event(event) do
      {:ok, decoded} -> send(parent, {:xai_realtime_event, self(), decoded})
      {:error, reason} -> send(parent, {:xai_realtime_error, self(), reason})
    end
  end
end
