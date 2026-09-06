defmodule FermixCore.Meetings.Rtms.Protocol do
  @moduledoc """
  Every Zoom RTMS wire literal, in one module.

  The Zoom lane speaks three sockets — the account event subscription, the
  meeting's signaling server, and its media server — and nothing else in Fermix
  knows a single string, key, or enum any of them uses. That is deliberate: the
  shapes below were synthesized from Zoom's RTMS documentation, not from a
  capture of a live stream, so the first real meeting is expected to correct
  some of them. Keeping every literal here makes each correction a one-module
  change instead of a hunt through a state machine.

  Pure and process-free: builders return maps for the transport to encode,
  decoders take an already-decoded map and return a closed vocabulary of tagged
  tuples. A shape this module does not recognize is `:ignored` (the sockets
  carry traffic we have no use for); a shape it recognizes but cannot use is a
  `{:protocol_error, reason}` that the source treats as terminal — never a
  silent skip.

  ## VALIDATE LIVE — unconfirmed against a real RTMS stream

    * `msg_type` discriminants are the documented symbolic names. If Zoom sends
      integer enums instead, only `@signaling_handshake_req` and its siblings
      change.
    * The signature payload is `client_id,meeting_uuid,rtms_stream_id` joined by
      commas, HMAC-SHA256 under the client secret, lower-case hex. The
      concatenation ORDER is the part most likely to be wrong.
    * The audio-stream request enums (`RAW_AUDIO`, `AUDIO_MULTI_CHANNELS`) and
      the flat `sample_rate: 16000` value — Zoom may name the rate `SR_16K`.
    * Whether the event socket replays `meeting.rtms_started` for a meeting that
      is already streaming when we subscribe. Today the source assumes it does
      not and bounds its wait instead.
    * The event socket's own heartbeat. v1 sends none: an invented heartbeat
      shape would be dropped by the server just as silently as sending nothing,
      and the keep-alive that carries the stream is on the media leg, which is
      answered exactly per `keepalive_response/1`.
    * Inbound audio fields are read from the top level of the media message. If
      Zoom nests them under a `content` object, `decode_media/1` grows one
      clause.
  """

  # --- Server-to-Server OAuth (the event socket's bearer token) ---

  @oauth_url "https://zoom.us/oauth/token"
  @oauth_grant_type "account_credentials"

  # --- Event subscription socket ---

  @event_ws_url "wss://ws.zoom.us/ws"
  @event_rtms_started "meeting.rtms_started"
  @event_rtms_stopped "meeting.rtms_stopped"

  # --- Signaling + media sockets ---

  @protocol_version 1
  @signaling_handshake_req "SIGNALING_HAND_SHAKE_REQ"
  @signaling_handshake_resp "SIGNALING_HAND_SHAKE_RESP"
  @data_handshake_req "DATA_HAND_SHAKE_REQ"
  @data_handshake_resp "DATA_HAND_SHAKE_RESP"
  @keep_alive_req "KEEP_ALIVE_REQ"
  @keep_alive_resp "KEEP_ALIVE_RESP"
  @media_data_audio "MEDIA_DATA_AUDIO"
  @stream_state_update "STREAM_STATE_UPDATE"
  @status_ok "STATUS_OK"
  @stream_terminated "TERMINATED"

  # Audio request enums. RTMS mixes every participant into one channel unless
  # multi-channel is asked for, and per-participant channels are the whole
  # reason this lane can attribute speakers without acoustic diarization.
  @audio_content_type "RAW_AUDIO"
  @audio_sample_rate 16_000
  @audio_channel "MONO"
  @audio_data_opt "AUDIO_MULTI_CHANNELS"

  # The handshake response names the media server under one of these keys —
  # `audio` when only audio was requested, `all` when the server offers one
  # socket for every media type. Preference order, not a fallback path.
  @media_url_keys ["audio", "all"]

  @typedoc "The meeting identifiers `meeting.rtms_started` hands us."
  @type stream_start :: %{
          meeting_no: String.t(),
          meeting_uuid: String.t(),
          rtms_stream_id: String.t(),
          server_urls: String.t()
        }

  @typedoc "What the event subscription socket told us."
  @type event ::
          {:rtms_started, stream_start()}
          | {:rtms_stopped, %{meeting_no: String.t()}}
          | {:protocol_error, term()}
          | :ignored

  @typedoc "What the signaling socket told us."
  @type signaling ::
          {:handshake_ok, String.t()}
          | {:handshake_failed, term()}
          | {:keepalive, term()}
          | {:protocol_error, term()}
          | :ignored

  @typedoc "What the media socket told us."
  @type media ::
          :handshake_ok
          | {:handshake_failed, term()}
          | {:keepalive, term()}
          | {:audio, audio_frame()}
          | {:stream_ended, term()}
          | {:protocol_error, term()}
          | :ignored

  @typedoc "One participant's audio for one instant, already base64-decoded."
  @type audio_frame :: %{
          user_id: String.t(),
          user_name: String.t(),
          timestamp: non_neg_integer(),
          pcm: binary()
        }

  @doc """
  The Server-to-Server OAuth token request: URL (grant type and account in the
  query, per Zoom) and Basic-auth headers built from the app credentials.
  """
  @spec oauth_request(String.t(), String.t(), String.t()) ::
          %{url: String.t(), headers: [{String.t(), String.t()}]}
  def oauth_request(account_id, client_id, client_secret)
      when is_binary(account_id) and is_binary(client_id) and is_binary(client_secret) do
    query = URI.encode_query(%{"grant_type" => @oauth_grant_type, "account_id" => account_id})
    basic = Base.encode64(client_id <> ":" <> client_secret)

    %{
      url: @oauth_url <> "?" <> query,
      headers: [
        {"authorization", "Basic " <> basic},
        {"content-type", "application/x-www-form-urlencoded"}
      ]
    }
  end

  @doc "Reads the bearer token out of an OAuth response body."
  @spec decode_oauth(map()) :: {:ok, String.t()} | {:error, :no_access_token}
  def decode_oauth(%{"access_token" => token}) when is_binary(token) and token != "",
    do: {:ok, token}

  def decode_oauth(_body), do: {:error, :no_access_token}

  @doc "The account event-subscription socket URL, token in the query string."
  @spec event_ws_url(String.t(), String.t()) :: String.t()
  def event_ws_url(subscription_id, access_token)
      when is_binary(subscription_id) and is_binary(access_token) do
    query =
      URI.encode_query(%{"subscriptionId" => subscription_id, "access_token" => access_token})

    @event_ws_url <> "?" <> query
  end

  @doc """
  The handshake signature: lower-case hex HMAC-SHA256 of
  `client_id,meeting_uuid,rtms_stream_id` under the app's client secret.
  """
  @spec signature(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def signature(client_id, client_secret, meeting_uuid, rtms_stream_id)
      when is_binary(client_id) and is_binary(client_secret) and is_binary(meeting_uuid) and
             is_binary(rtms_stream_id) do
    payload = Enum.join([client_id, meeting_uuid, rtms_stream_id], ",")

    :hmac
    |> :crypto.mac(:sha256, client_secret, payload)
    |> Base.encode16(case: :lower)
  end

  @doc "The signaling socket's opening request."
  @spec signaling_handshake(String.t(), String.t(), String.t()) :: map()
  def signaling_handshake(meeting_uuid, rtms_stream_id, signature)
      when is_binary(meeting_uuid) and is_binary(rtms_stream_id) and is_binary(signature) do
    %{
      "msg_type" => @signaling_handshake_req,
      "protocol_version" => @protocol_version,
      "meeting_uuid" => meeting_uuid,
      "rtms_stream_id" => rtms_stream_id,
      "signature" => signature
    }
  end

  @doc """
  The media socket's opening request — 16 kHz mono raw audio, one channel per
  participant.
  """
  @spec media_handshake(String.t(), String.t(), String.t()) :: map()
  def media_handshake(meeting_uuid, rtms_stream_id, signature)
      when is_binary(meeting_uuid) and is_binary(rtms_stream_id) and is_binary(signature) do
    %{
      "msg_type" => @data_handshake_req,
      "protocol_version" => @protocol_version,
      "meeting_uuid" => meeting_uuid,
      "rtms_stream_id" => rtms_stream_id,
      "signature" => signature,
      "payload_encryption" => false,
      "media_params" => %{
        "audio" => %{
          "content_type" => @audio_content_type,
          "sample_rate" => @audio_sample_rate,
          "channel" => @audio_channel,
          "data_opt" => @audio_data_opt
        }
      }
    }
  end

  @doc "The reply to a `KEEP_ALIVE_REQ`, echoing its timestamp verbatim."
  @spec keepalive_response(term()) :: map()
  def keepalive_response(timestamp) do
    %{"msg_type" => @keep_alive_resp, "timestamp" => timestamp}
  end

  @doc "Decodes one message from the account event-subscription socket."
  @spec decode_event(map()) :: event()
  def decode_event(%{"content" => content}) when is_binary(content) do
    # The subscription socket wraps each webhook in an envelope whose payload is
    # a JSON *string*. Unwrapped exactly once — the inner decoder never unwraps.
    case Jason.decode(content) do
      {:ok, %{} = webhook} ->
        decode_webhook(webhook)

      {:error, reason} ->
        {:protocol_error, {:undecodable_event_envelope, Exception.message(reason)}}
    end
  end

  def decode_event(%{} = message), do: decode_webhook(message)

  @doc "Decodes one message from the signaling socket."
  @spec decode_signaling(map()) :: signaling()
  def decode_signaling(
        %{"msg_type" => @signaling_handshake_resp, "status_code" => @status_ok} = message
      ) do
    case media_audio_url(message) do
      {:ok, url} -> {:handshake_ok, url}
      :error -> {:protocol_error, :no_media_server_url}
    end
  end

  def decode_signaling(%{"msg_type" => @signaling_handshake_resp} = message),
    do: {:handshake_failed, failure_reason(message)}

  def decode_signaling(%{} = message), do: decode_control(message)

  @doc "Decodes one message from the media socket."
  @spec decode_media(map()) :: media()
  def decode_media(%{"msg_type" => @data_handshake_resp, "status_code" => @status_ok}),
    do: :handshake_ok

  def decode_media(%{"msg_type" => @data_handshake_resp} = message),
    do: {:handshake_failed, failure_reason(message)}

  def decode_media(%{"msg_type" => @media_data_audio} = message), do: decode_audio(message)

  def decode_media(
        %{"msg_type" => @stream_state_update, "state" => @stream_terminated} = message
      ),
      do: {:stream_ended, failure_reason(message)}

  def decode_media(%{} = message), do: decode_control(message)

  # --- Private ---

  defp decode_webhook(%{"event" => @event_rtms_started, "payload" => %{"object" => object}}),
    do: started(object)

  defp decode_webhook(%{"event" => @event_rtms_stopped, "payload" => %{"object" => object}}),
    do: stopped(object)

  defp decode_webhook(_message), do: :ignored

  defp started(%{
         "id" => meeting_no,
         "meeting_uuid" => uuid,
         "rtms_stream_id" => stream_id,
         "server_urls" => server_urls
       })
       when is_binary(meeting_no) and is_binary(uuid) and is_binary(stream_id) and
              is_binary(server_urls) do
    {:rtms_started,
     %{
       meeting_no: meeting_no,
       meeting_uuid: uuid,
       rtms_stream_id: stream_id,
       server_urls: server_urls
     }}
  end

  defp started(_object), do: {:protocol_error, :incomplete_rtms_started}

  defp stopped(%{"id" => meeting_no}) when is_binary(meeting_no),
    do: {:rtms_stopped, %{meeting_no: meeting_no}}

  defp stopped(_object), do: {:protocol_error, :incomplete_rtms_stopped}

  defp decode_control(%{"msg_type" => @keep_alive_req} = message),
    do: {:keepalive, Map.get(message, "timestamp")}

  defp decode_control(_message), do: :ignored

  defp media_audio_url(%{"media_server" => %{"server_urls" => %{} = urls}}) do
    Enum.find_value(@media_url_keys, :error, fn key ->
      case Map.get(urls, key) do
        url when is_binary(url) and url != "" -> {:ok, url}
        _absent -> nil
      end
    end)
  end

  defp media_audio_url(_message), do: :error

  defp failure_reason(message) do
    %{
      status_code: Map.get(message, "status_code"),
      reason: Map.get(message, "reason")
    }
  end

  defp decode_audio(%{
         "user_id" => user_id,
         "user_name" => user_name,
         "timestamp" => timestamp,
         "data" => data
       })
       when is_binary(user_id) and is_binary(user_name) and is_integer(timestamp) and
              timestamp >= 0 and is_binary(data) do
    case Base.decode64(data) do
      {:ok, pcm} ->
        {:audio, %{user_id: user_id, user_name: user_name, timestamp: timestamp, pcm: pcm}}

      :error ->
        {:protocol_error, :undecodable_audio_payload}
    end
  end

  defp decode_audio(_message), do: {:protocol_error, :incomplete_audio_message}
end
