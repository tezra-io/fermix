defmodule FermixChannels.Companion.Output do
  @moduledoc """
  What a chat turn writes and says, shared by the two companion transports'
  channel adapters (`Channels.Mobile` and `Channels.Companion`).

  It owns the timeline rows a reply becomes (a request's outputs fenced by its
  attempt, a proactive delivery deduplicated by its key, or a plain append),
  the settlement of the request that asked for them, and the logical chat
  events (`%{"t" => type, ...}`) a turn produces. Each transport frames those
  events in its own envelope and fans them out its own way; nothing here does
  I/O beyond the store it is handed.

  An absent optional field is an absent key, never an explicit null.
  """

  @sandbox_ttl_s 60
  @soul_ttl_s 300

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
      "detail" => inspect(detail)
    }

  def tool_event(turn_id, event),
    do: %{
      "t" => "tool_event",
      "turn_id" => turn_id,
      "tool" => "unknown",
      "phase" => "stop",
      "detail" => inspect(event)
    }

  @doc "A turn's terminal failure, `cancelled` included."
  @spec turn_error(String.t(), term()) :: event()
  def turn_error(turn_id, reason),
    do: %{
      "t" => "turn_error",
      "turn_id" => turn_id,
      "code" => error_code(reason),
      "message" => error_message(reason)
    }

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
      metadata: %{"turn_id" => value(attrs, :turn_id)}
    }
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
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
