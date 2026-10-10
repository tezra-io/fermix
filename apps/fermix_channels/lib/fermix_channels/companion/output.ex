defmodule FermixChannels.Companion.Output do
  @moduledoc """
  What a chat turn writes and says, shared by the two companion transports'
  channel adapters (`Channels.Mobile` and `Channels.Companion`).

  It owns the timeline rows a reply becomes (a request's outputs fenced by its
  attempt, a proactive delivery deduplicated by its key, or a plain append),
  the settlement of the request that asked for them, the logical chat events
  (`%{"t" => type, ...}`) a turn produces, and the exported shape of a row that
  history pages and `row` events carry. Each transport frames those events in
  its own envelope and fans them out its own way; nothing here does I/O beyond
  the store it is handed.

  An absent optional field is an absent key, never an explicit null.
  """

  alias FermixCore.Text

  @sandbox_ttl_s 60
  @soul_ttl_s 300
  # A failure reason or a tool's result can be any term, and an event header is
  # capped: its text is cut to these many bytes. Every error message of both
  # wires takes the first bound (`error_message/1`).
  @max_error_message_bytes 512
  @max_tool_detail_bytes 512

  @typedoc "A `FermixCore.Companion.Timeline`-shaped store module."
  @type store :: module()
  @type event :: %{required(String.t()) => term()}
  @type persisted :: {:ok, {:created | :existing, map()}} | {:error, term()}

  @typedoc """
  The approval card a gateway approval becomes. `approval_id`, `detail` and
  `ttl_s` are optional; the kind picks the command routes and the default ttl.
  """
  @type approval_spec :: %{
          required(:kind) => :sandbox | :soul,
          required(:text) => String.t(),
          required(:token) => String.t(),
          optional(:approval_id) => String.t(),
          optional(:detail) => String.t() | nil,
          optional(:ttl_s) => pos_integer()
        }

  @doc "Stable opaque identifier shared by an approval and its resolution."
  @spec approval_id(:sandbox | :soul, String.t()) :: String.t()
  def approval_id(kind, token)
      when kind in [:sandbox, :soul] and is_binary(token) and token != "" do
    digest = :crypto.hash(:sha256, "#{kind}:#{token}")
    "#{kind}-" <> Base.url_encode64(digest, padding: false)
  end

  @doc "A turn began answering `in_reply_to`."
  @spec turn_started(String.t(), String.t(), String.t()) :: event()
  def turn_started(profile_id, turn_id, in_reply_to) do
    %{
      "t" => "turn_started",
      "profile_id" => profile_id,
      "turn_id" => turn_id,
      "in_reply_to" => in_reply_to
    }
  end

  @doc "One streamed piece of a turn's reply."
  @spec text_delta(String.t(), String.t()) :: event()
  def text_delta(turn_id, text), do: %{"t" => "text_delta", "turn_id" => turn_id, "text" => text}

  @doc "A reply's canonical text, at its timeline row."
  @spec text_done(String.t(), pos_integer(), String.t()) :: event()
  def text_done(turn_id, server_seq, text),
    do: %{"t" => "text_done", "turn_id" => turn_id, "server_seq" => server_seq, "text" => text}

  @doc "One tool-lifecycle event of a turn's activity feed."
  @spec tool_event(String.t(), term()) :: event()
  def tool_event(turn_id, {:tool_start, tool}),
    do: %{"t" => "tool_event", "turn_id" => turn_id, "tool" => tool, "phase" => "start"}

  def tool_event(turn_id, {:tool_finish, tool, detail}),
    do: %{
      "t" => "tool_event",
      "turn_id" => turn_id,
      "tool" => tool,
      "phase" => "stop",
      "detail" => detail |> inspect() |> Text.truncate_utf8(@max_tool_detail_bytes)
    }

  def tool_event(turn_id, event),
    do: %{
      "t" => "tool_event",
      "turn_id" => turn_id,
      "tool" => "unknown",
      "phase" => "stop",
      "detail" => event |> inspect() |> Text.truncate_utf8(@max_tool_detail_bytes)
    }

  @doc """
  A completed turn's ending, for the connections that streamed it: every
  phone turn's, after the rows it wrote (mobile protocol 2), and a Mac turn's
  that wrote no reply (companion protocol 2, M56 §4.4).
  """
  @spec turn_done(String.t()) :: event()
  def turn_done(turn_id) when is_binary(turn_id) and turn_id != "",
    do: %{"t" => "turn_done", "turn_id" => turn_id}

  @doc "A turn's terminal failure, `cancelled` included."
  @spec turn_error(String.t(), term()) :: event()
  def turn_error(turn_id, reason),
    do: %{
      "t" => "turn_error",
      "turn_id" => turn_id,
      "code" => error_code(reason),
      "message" => turn_error_message(reason)
    }

  @doc """
  A failure reason as the `message` of an error on either wire: its shallow
  inspection, cut to 512 bytes, never inside a UTF-8 code point. A reason can
  carry an exception and its stacktrace, so the event that reports it can
  always be written.
  """
  @spec error_message(term()) :: String.t()
  def error_message(reason) do
    reason
    |> inspect(limit: 5, printable_limit: 256)
    |> Text.truncate_utf8(@max_error_message_bytes)
  end

  @doc """
  The `row` event that announces one timeline row as it is written, in the
  phone's shape: the row's history message (`timeline_message/1`), its text as
  `text`, and the profile, so a phone renders a row it did not write as a
  history page gives it. `Companion.Fanout` gives the Mac's wire only the
  fields its own `row` has.
  """
  @spec row(String.t(), map()) :: event()
  def row(profile_id, row) when is_binary(profile_id) and is_map(row) do
    {:ok, %{"content" => text} = message} = timeline_message(row)

    message
    |> Map.delete("content")
    |> Map.merge(%{"t" => "row", "profile_id" => profile_id, "text" => text})
  end

  @doc """
  The exported shape of one timeline row, a history page's message. Internal
  columns never ship, so a column added later can never leak to a client, and
  `ts` is always there. A row's link previews ship as the cards `link_preview`
  sent, the image as its ref. Nothing ships as an explicit null.
  """
  @spec timeline_message(map()) :: {:ok, map()} | {:error, term()}
  def timeline_message(
        %{server_seq: seq, role: role, content: content, created_at: %DateTime{} = created_at} =
          row
      )
      when is_integer(seq) and seq > 0 and is_binary(role) and is_binary(content) do
    message =
      %{
        "server_seq" => seq,
        "role" => role,
        "content" => content,
        "ts" => DateTime.to_iso8601(created_at),
        "media_refs" => Map.get(row, :media_refs) || []
      }
      |> maybe_put("kind", Map.get(row, :kind))
      |> maybe_put("client_msg_id", Map.get(row, :client_msg_id))
      |> maybe_put("in_reply_to", Map.get(row, :in_reply_to))
      |> maybe_put("metadata", present_metadata(Map.get(row, :metadata)))
      |> maybe_put("link_previews", preview_cards(Map.get(row, :link_previews)))

    {:ok, message}
  end

  def timeline_message(row), do: {:error, {:invalid_timeline_row, Map.get(row, :server_seq)}}

  @doc """
  An owner-approval card with its exact approve and deny command routes. The
  routes are scrubbed from the display text, which already names them.
  """
  @spec approval(approval_spec()) :: event()
  def approval(%{kind: kind, text: text, token: token} = spec)
      when kind in [:sandbox, :soul] and is_binary(text) and is_binary(token) do
    {approve, deny, ttl} = approval_routes(kind, token)
    clean_text = text |> scrub_command(approve) |> scrub_command(deny) |> String.trim()

    %{
      "t" => "approval",
      "approval_id" => Map.get(spec, :approval_id, approval_id(kind, token)),
      "kind" => Atom.to_string(kind),
      "text" => clean_text,
      "token" => token,
      "ttl_s" => Map.get(spec, :ttl_s, ttl),
      "approve_command" => approve,
      "deny_command" => deny
    }
    |> maybe_put("detail", Map.get(spec, :detail))
  end

  @doc "How an approval ended."
  @spec approval_resolved(:sandbox | :soul, String.t(), atom()) :: event()
  def approval_resolved(kind, token, outcome) when is_atom(outcome) do
    %{
      "t" => "approval_resolved",
      "approval_id" => approval_id(kind, token),
      "outcome" => Atom.to_string(outcome)
    }
  end

  @doc """
  Persist one reply text. `attrs` names what the text answers: a request's
  `:in_reply_to` and `:attempt` make it that attempt's output, keyed by the
  text's digest; a `:proactive_key` (with an optional `:proactive_part_id`)
  makes it a deduplicated proactive delivery; neither makes it a plain row.
  The row's metadata carries the `:turn_id` that wrote it and a Live call's
  `:call` map (M56 §6), already validated by its writer, each when given.
  """
  @spec persist_text(store(), String.t(), String.t(), map()) :: persisted()
  def persist_text(store, profile_id, text, attrs) when is_binary(text) and is_map(attrs) do
    persist_output(store, profile_id, text_timeline_attrs(text, attrs), attrs, text_key(text))
  end

  @doc """
  Persist one reply part under an explicit output key; the router behind
  `persist_text/4`, also used for media parts.
  """
  @spec persist_output(store(), String.t(), map(), map(), String.t()) :: persisted()
  def persist_output(store, profile_id, timeline_attrs, attrs, output_key) do
    cond do
      client_output?(attrs) ->
        store.append_client_output(
          profile_id,
          value(attrs, :in_reply_to),
          value(attrs, :attempt),
          output_key,
          Map.delete(timeline_attrs, :role),
          []
        )

      proactive_key = value(attrs, :proactive_key) ->
        proactive_key = proactive_output_key(proactive_key, attrs)
        store.append_proactive(profile_id, proactive_key, timeline_attrs, [])

      true ->
        case store.append(profile_id, timeline_attrs, []) do
          {:ok, row} -> {:ok, {:created, row}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Persist a request's authoritative final text and complete the request in the
  same transaction.
  """
  @spec persist_final_text(store(), String.t(), map(), String.t()) :: persisted()
  def persist_final_text(
        store,
        profile_id,
        %{in_reply_to: client_id, attempt: attempt} = attrs,
        text
      ) do
    store.append_client_response(
      profile_id,
      client_id,
      attempt,
      text |> text_timeline_attrs(attrs) |> Map.delete(:role),
      []
    )
  end

  @doc """
  Complete a request after its last output. A request the store no longer has
  was settled already, which is not an error here.
  """
  @spec complete_request(store(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | :ok | {:error, term()}
  def complete_request(store, profile_id, client_id, attempt) do
    case store.complete_client_request(profile_id, client_id, attempt, %{}, []) do
      {:ok, request} -> {:ok, request}
      {:error, :not_found} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc "Settle a request as failed, recording why."
  @spec fail_request(store(), String.t(), String.t(), non_neg_integer(), term()) ::
          :ok | {:error, term()}
  def fail_request(store, profile_id, client_id, attempt, reason) do
    case store.fail_client_request(profile_id, client_id, attempt, %{error: inspect(reason)}, []) do
      {:ok, _request} -> :ok
      {:error, :not_found} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp text_timeline_attrs(text, attrs) do
    %{
      role: "assistant",
      content: text,
      kind: "text",
      in_reply_to: value(attrs, :in_reply_to),
      metadata: text_metadata(value(attrs, :turn_id), value(attrs, :call))
    }
  end

  # A reply outside any turn (a delivery) has no turn to name, and only a Live
  # call's row has a call. A row with neither stores no metadata.
  defp text_metadata(turn_id, call) do
    case Enum.reject([{"turn_id", turn_id}, {"call", call}], &is_nil(elem(&1, 1))) do
      [] -> nil
      present -> Map.new(present)
    end
  end

  defp client_output?(attrs) do
    is_binary(value(attrs, :in_reply_to)) and value(attrs, :in_reply_to) != "" and
      is_integer(value(attrs, :attempt)) and value(attrs, :attempt) > 0
  end

  defp proactive_output_key(key, attrs) do
    case value(attrs, :proactive_part_id) do
      nil -> key
      part_id -> "#{key}:#{part_id}"
    end
  end

  defp text_key(text), do: "text:" <> content_digest(text)

  defp content_digest(content) do
    :crypto.hash(:sha256, content)
    |> Base.url_encode64(padding: false)
  end

  defp approval_routes(:sandbox, token),
    do: {"/confirm #{token}", "/deny #{token}", @sandbox_ttl_s}

  defp approval_routes(:soul, token),
    do: {"/soul apply #{token}", "/soul deny #{token}", @soul_ttl_s}

  defp scrub_command(text, command), do: String.replace(text, command, "", global: true)

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "turn_failed"
  defp turn_error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp turn_error_message(reason), do: error_message(reason)

  # A row stored before metadata dropped its nulls still carries them.
  defp present_metadata(metadata) when is_map(metadata) do
    present = Map.reject(metadata, fn {_key, value} -> is_nil(value) end)
    if map_size(present) == 0, do: nil, else: present
  end

  defp present_metadata(metadata), do: metadata

  defp preview_cards(previews) when is_list(previews) and previews != [] do
    Enum.map(previews, fn preview ->
      preview
      |> Map.take(~w(url site title description))
      |> maybe_put("image_ref", get_in(preview, ["image", "ref"]))
    end)
  end

  defp preview_cards(_previews), do: nil

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
