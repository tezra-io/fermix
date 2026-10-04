defmodule FermixChannels.Channels.IMessage.Protocol do
  @moduledoc """
  The pure NDJSON codec for the Fermix Messages helper wire, protocol v1
  (docs/design/MILESTONE_54_IMESSAGE_CHANNEL.md §6).

  One JSON object per line. Requests are `{"id", "method", "params"}`; responses
  are `{"id", "result"}` or `{"id", "error": {"kind", "message", "data"}}`;
  notifications are `{"event", "params"}`. Methods, events and error kinds are
  closed sets: an unknown method is refused before it reaches the wire, and an
  unknown event or error kind arriving from the helper is refused with a typed
  error instead of being guessed at.

  The helper's `Protocol.swift` is golden-tested against the same fixture files
  as this module (`test/fixtures/imessage/protocol/`), and the two are pinned to
  each other by `protocol_version/0` at `initialize`: a helper release that
  changes the wire moves this number and the engine pin together.

  Payloads stay JSON-shaped maps with string keys; interpreting a result is the
  caller's job. This module also owns the one handle-normalization rule both
  sides apply (§7.4) and the redaction every log line uses (§13).
  """

  @protocol_version 1

  @methods ~w(initialize probe grant policy.get policy.set watch.subscribe watch.unsubscribe
              messages.after send.text send.file attachment.fetch shutdown)

  @events ~w(message watch.overflow db.state send.reconciled)

  @error_kinds %{
    "not_initialized" => :not_initialized,
    "protocol_mismatch" => :protocol_mismatch,
    "permission_denied" => :permission_denied,
    "db_missing" => :db_missing,
    "db_unreadable" => :db_unreadable,
    "db_schema_unexpected" => :db_schema_unexpected,
    "policy_absent" => :policy_absent,
    "policy_unconfirmed" => :policy_unconfirmed,
    "policy_refused" => :policy_refused,
    "policy_violation" => :policy_violation,
    "owner_not_self" => :owner_not_self,
    "not_signed_in" => :not_signed_in,
    "no_user_session" => :no_user_session,
    "service_not_imessage" => :service_not_imessage,
    "chat_not_found" => :chat_not_found,
    "automation_refused" => :automation_refused,
    "send_timeout" => :send_timeout,
    "path_refused" => :path_refused,
    "attachment_not_admitted" => :attachment_not_admitted,
    "attachment_too_large" => :attachment_too_large,
    "busy" => :busy
  }

  @type error_kind ::
          :not_initialized
          | :protocol_mismatch
          | :permission_denied
          | :db_missing
          | :db_unreadable
          | :db_schema_unexpected
          | :policy_absent
          | :policy_unconfirmed
          | :policy_refused
          | :policy_violation
          | :owner_not_self
          | :not_signed_in
          | :no_user_session
          | :service_not_imessage
          | :chat_not_found
          | :automation_refused
          | :send_timeout
          | :path_refused
          | :attachment_not_admitted
          | :attachment_too_large
          | :busy

  @typedoc "A helper error: its closed kind, the helper's own words, and its data."
  @type helper_error :: {error_kind(), String.t(), map()}

  @type frame ::
          {:response, non_neg_integer(), {:ok, map()} | {:error, helper_error()}}
          | {:notification, String.t(), map()}

  @type decode_error ::
          :invalid_json
          | :not_an_object
          | :malformed_frame
          | {:unknown_event, String.t()}
          | {:unknown_error_kind, non_neg_integer(), String.t()}

  @doc "The wire version this engine speaks; `initialize` refuses any other."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: @protocol_version

  @doc "The closed set of request methods."
  @spec methods() :: [String.t()]
  def methods, do: @methods

  @doc "The closed set of notification events."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The closed set of helper error kinds, as atoms."
  @spec error_kinds() :: [error_kind()]
  def error_kinds, do: Map.values(@error_kinds)

  @doc "The `initialize` params for a client running engine version `version`."
  @spec initialize_params(String.t()) :: map()
  def initialize_params(version) when is_binary(version) do
    %{"protocol_version" => @protocol_version, "client" => "fermix " <> version}
  end

  @doc """
  Encodes one request as a single newline-terminated line. A method outside the
  closed set is refused: nothing the helper does not know ever reaches its stdin.
  """
  @spec encode_request(non_neg_integer(), String.t(), map()) ::
          {:ok, binary()} | {:error, {:unknown_method, String.t()}}
  def encode_request(id, method, params)
      when is_integer(id) and id >= 0 and is_binary(method) and is_map(params) do
    if method in @methods do
      {:ok, Jason.encode!(%{"id" => id, "method" => method, "params" => params}) <> "\n"}
    else
      {:error, {:unknown_method, method}}
    end
  end

  @doc "Decodes one line from the helper's stdout into a typed frame."
  @spec decode(binary()) :: {:ok, frame()} | {:error, decode_error()}
  def decode(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, object} when is_map(object) -> decode_frame(object)
      {:ok, _other} -> {:error, :not_an_object}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  @doc "Maps a wire error kind onto its closed atom; an unknown kind is refused."
  @spec decode_error_kind(String.t()) ::
          {:ok, error_kind()} | {:error, {:unknown_error_kind, String.t()}}
  def decode_error_kind(kind) when is_binary(kind) do
    case Map.fetch(@error_kinds, kind) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:unknown_error_kind, kind}}
    end
  end

  @doc "The one handle-normalization rule (§7.4), owned by `FermixCore.IMessage`."
  @spec normalize_handle(term()) :: {:ok, String.t()} | {:error, :invalid_handle}
  defdelegate normalize_handle(handle), to: FermixCore.IMessage

  @doc """
  A handle as it may appear in a log line (§13): the country code and last four
  digits of a phone number, the first letter and domain of an email.
  """
  @spec redact_handle(String.t()) :: String.t()
  def redact_handle(handle) when is_binary(handle) do
    case String.split(handle, "@", parts: 2) do
      [local, domain] when local != "" -> String.first(local) <> "…@" <> domain
      _phone -> redact_phone(handle)
    end
  end

  defp decode_frame(%{"id" => id, "result" => result})
       when is_integer(id) and id >= 0 and is_map(result),
       do: {:ok, {:response, id, {:ok, result}}}

  defp decode_frame(%{"id" => id, "error" => %{"kind" => kind, "message" => message} = error})
       when is_integer(id) and id >= 0 and is_binary(kind) and is_binary(message) do
    case {decode_error_kind(kind), error_data(error)} do
      {{:ok, atom}, {:ok, data}} -> {:ok, {:response, id, {:error, {atom, message, data}}}}
      {{:error, {:unknown_error_kind, kind}}, _data} -> {:error, {:unknown_error_kind, id, kind}}
      {{:ok, _atom}, :error} -> {:error, :malformed_frame}
    end
  end

  defp decode_frame(%{"event" => event, "params" => params})
       when is_binary(event) and is_map(params) do
    if event in @events,
      do: {:ok, {:notification, event, params}},
      else: {:error, {:unknown_event, event}}
  end

  defp decode_frame(_object), do: {:error, :malformed_frame}

  defp error_data(error) do
    case Map.get(error, "data") do
      nil -> {:ok, %{}}
      data when is_map(data) -> {:ok, data}
      _other -> :error
    end
  end

  defp redact_phone(handle) do
    if String.length(handle) >= 10,
      do: String.slice(handle, 0, 5) <> "…" <> String.slice(handle, -4, 4),
      else: "…"
  end
end
