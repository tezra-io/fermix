defmodule FermixCore.PhoneCalls.OpenAILive.Controls do
  @moduledoc """
  The client events a phone call's sideband sends, built as plain maps, and
  the correlation that matches an acknowledgement to the event it answers.

  Pure: `Sideband` sends what these build. The append events are the local
  voice client's own (`Realtime.OpenAILiveClient`), because the sideband takes
  the same `session.instructions.append`, `session.thinking.append` and
  `session.commentary.append`, with `delegation_id` always present and `null`
  meaning the whole session (OpenAI, *Sideband WebSocket* reference). Content is
  plain text of at most 500 tokens per append; the caller keeps it short, since
  only the vendor can count its tokens.

  ## Keypad

  `transport.dtmf.send` carries exactly one key, `0`-`9`, `A`-`D`, `*` or `#`,
  and an `event_id`. Success comes back as `transport.dtmf.sent` with that id as
  `client_event_id`; a refusal as `error` with it as `error.client_event_id`.
  `dtmf_outcome/2` reads either. One key per event: a sequence is the caller's,
  key by key, each after the previous one's acknowledgement. An acknowledgement
  that never comes leaves the key unconfirmed, not unsent, and a key is never
  sent again because its acknowledgement is late.
  """

  alias FermixCore.PhoneCalls.OpenAILive.Events
  alias FermixCore.Realtime.OpenAILiveClient

  @dtmf_key ~r/\A[0-9A-D*#]\z/

  @doc "A fresh client event id, unique for the life of this node."
  @spec new_event_id() :: String.t()
  def new_event_id, do: OpenAILiveClient.new_event_id()

  @doc """
  One keypad press. `{:error, :invalid_dtmf_key}` for anything but a single
  allowed key; the refusal never repeats the value.
  """
  @spec dtmf_event(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_dtmf_key}
  def dtmf_event(event_id, key) when is_binary(event_id) and event_id != "" and is_binary(key) do
    if Regex.match?(@dtmf_key, key),
      do: {:ok, %{type: "transport.dtmf.send", event_id: event_id, event: key}},
      else: {:error, :invalid_dtmf_key}
  end

  @doc """
  What a normalized event says about the keypad send that carried `event_id`:
  `:acknowledged`, `{:refused, vendor_error}` in the vendor's words, or
  `:unrelated` for any other event.
  """
  @spec dtmf_outcome(String.t(), Events.t()) ::
          :acknowledged | {:refused, map()} | :unrelated
  def dtmf_outcome(event_id, {:dtmf_sent, %{client_event_id: event_id}}) when is_binary(event_id),
    do: :acknowledged

  def dtmf_outcome(event_id, {:vendor_error, %{client_event_id: event_id} = error})
      when is_binary(event_id),
      do: {:refused, error}

  def dtmf_outcome(event_id, _event) when is_binary(event_id), do: :unrelated

  @doc "Spoken context: a delegation's result, or with `nil` something for the whole call."
  @spec commentary_event(String.t(), String.t() | nil, String.t()) :: map()
  def commentary_event(event_id, delegation_id, content)
      when is_binary(event_id) and (is_binary(delegation_id) or is_nil(delegation_id)) and
             is_binary(content) do
    {^event_id, event} =
      OpenAILiveClient.commentary_append_event(event_id, delegation_id, content)

    event
  end

  @doc "Quiet context: progress on a delegation, never spoken when it arrives."
  @spec thinking_event(String.t(), String.t() | nil, String.t()) :: map()
  def thinking_event(event_id, delegation_id, content)
      when is_binary(event_id) and (is_binary(delegation_id) or is_nil(delegation_id)) and
             is_binary(content) do
    {^event_id, event} = OpenAILiveClient.thinking_append_event(event_id, delegation_id, content)
    event
  end

  @doc "A session-wide instruction (`delegation_id` is `null`)."
  @spec instructions_event(String.t(), String.t()) :: map()
  def instructions_event(event_id, content) when is_binary(event_id) and is_binary(content) do
    {^event_id, event} = OpenAILiveClient.instructions_append_event(event_id, nil, content)
    event
  end

  @doc """
  `session.close`: the graceful close. The server cancels queued work, rejects
  further commands and ends with `session.closed`, which carries the reason and
  final usage. Keep the sideband open until it arrives.
  """
  @spec close_event(String.t()) :: map()
  def close_event(event_id) when is_binary(event_id), do: OpenAILiveClient.close_event(event_id)

  @doc """
  What a normalized event says about an append that carried `event_id`:
  `:acknowledged`, `{:refused, vendor_error}` or `:unrelated`.
  """
  @spec append_outcome(String.t(), Events.t()) ::
          :acknowledged | {:refused, map()} | :unrelated
  def append_outcome(event_id, {:append_acked, %{client_event_id: event_id}})
      when is_binary(event_id),
      do: :acknowledged

  def append_outcome(event_id, {:vendor_error, %{client_event_id: event_id} = error})
      when is_binary(event_id),
      do: {:refused, error}

  def append_outcome(event_id, _event) when is_binary(event_id), do: :unrelated
end
