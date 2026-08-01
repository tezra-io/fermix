defmodule FermixChannels.Channels.Acp.Session do
  @moduledoc """
  One ACP session as **plain state owned by its Peer** — never a process
  (MILESTONE_29_ACP_AGENT_SURFACE.md §6.1). A session is its id, the `cwd` the
  client opened it with, an optional title for logs, and the bookkeeping for the
  one turn that may be in flight.

  Everything here is pure: minting an id, folding a prompt's ContentBlocks
  (§8.2), computing the unsent suffix of a cumulative stream snapshot (§8.4), and
  bracketing tool calls. The Peer owns the socket and the writes; this module
  owns what a session *is*.

  ## The turn fence

  `start_turn/2` stamps a strictly increasing `seq` onto the turn and returns it.
  That number travels out on the inbound message and comes back on every stream,
  activity, and outcome event, so the Peer can answer one question before it
  writes anything: is this event about the turn that is open right now? After the
  terminal response `clear_turn/1` closes the fence and every late event for that
  seq is dropped (§8.5) — the Queue's freshness check is check-then-act, so the
  *wire* is kept clean here rather than pretended to be atomic upstream.
  """

  @enforce_keys [:id, :cwd]
  defstruct [:id, :cwd, :title, turn_seq: 0, turn: nil]

  @typedoc """
  In-flight turn state: the wire id of the `session/prompt` request it answers,
  the fence `seq`, how many bytes of the reply have been written as chunks, and
  the tool-card ids minted so far.
  """
  @type turn :: %{
          seq: pos_integer(),
          request_id: String.t() | number(),
          sent_len: non_neg_integer(),
          final_seen?: boolean(),
          tool_seq: non_neg_integer(),
          tools: %{String.t() => String.t()}
        }

  @type t :: %__MODULE__{
          id: String.t(),
          cwd: String.t(),
          title: String.t() | nil,
          turn_seq: non_neg_integer(),
          turn: turn() | nil
        }

  @id_bytes 16

  @doc "Mint a session with a fresh id. `cwd` is the client's absolute workspace root."
  @spec new(String.t(), String.t() | nil) :: t()
  def new(cwd, title) when is_binary(cwd) and (is_binary(title) or is_nil(title)) do
    %__MODULE__{id: mint_id(), cwd: cwd, title: title}
  end

  @doc "A session id: `acp-` plus 32 lowercase hex characters of strong randomness."
  @spec mint_id() :: String.t()
  def mint_id do
    "acp-" <> Base.encode16(:crypto.strong_rand_bytes(@id_bytes), case: :lower)
  end

  @doc """
  Fold a prompt's ContentBlocks into one model input (§8.2).

  `text` verbatim, `resource_link` as a bracketed reference, blocks joined by a
  blank line. The capability-gated kinds (`image`, `audio`, `resource`) and any
  unknown kind are refused by name — this agent advertises `promptCapabilities:
  {}`, so accepting them would be a lie the client could not have known about.
  """
  @spec fold_prompt(term()) ::
          {:ok, String.t()}
          | {:error, {:unsupported_block, String.t()} | :empty_prompt | :malformed_prompt}
  def fold_prompt(blocks) when is_list(blocks) do
    Enum.reduce_while(blocks, {:ok, []}, fn block, {:ok, acc} ->
      case fold_block(block) do
        {:ok, text} -> {:cont, {:ok, [text | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> join_blocks()
  end

  def fold_prompt(_blocks), do: {:error, :malformed_prompt}

  @doc """
  Open a turn for the `session/prompt` request `request_id`, returning the
  session and the fence sequence stamped on it.
  """
  @spec start_turn(t(), String.t() | number()) :: {t(), pos_integer()}
  def start_turn(%__MODULE__{turn: nil} = session, request_id)
      when is_binary(request_id) or is_number(request_id) do
    seq = session.turn_seq + 1

    turn = %{
      seq: seq,
      request_id: request_id,
      sent_len: 0,
      final_seen?: false,
      tool_seq: 0,
      tools: %{}
    }

    {%{session | turn_seq: seq, turn: turn}, seq}
  end

  @doc "Close the fence: the turn is answered, every later event for it is late."
  @spec clear_turn(t()) :: t()
  def clear_turn(%__MODULE__{} = session), do: %{session | turn: nil}

  @doc "Is `seq` the turn this session has open right now?"
  @spec turn_open?(t(), term()) :: boolean()
  def turn_open?(%__MODULE__{turn: %{seq: seq}}, seq), do: true
  def turn_open?(%__MODULE__{}, _seq), do: false

  @doc "The wire id of the in-flight prompt request, or nil."
  @spec request_id(t()) :: String.t() | number() | nil
  def request_id(%__MODULE__{turn: %{request_id: request_id}}), do: request_id
  def request_id(%__MODULE__{turn: nil}), do: nil

  @doc "Has the authoritative final reply for the open turn already been written?"
  @spec final_seen?(t()) :: boolean()
  def final_seen?(%__MODULE__{turn: %{final_seen?: seen?}}), do: seen?
  def final_seen?(%__MODULE__{turn: nil}), do: false

  @spec mark_final_seen(t()) :: t()
  def mark_final_seen(%__MODULE__{turn: turn} = session) when is_map(turn) do
    %{session | turn: %{turn | final_seen?: true}}
  end

  @doc """
  The part of a cumulative snapshot that has not been written yet, and the
  session with the write accounted for.

  A snapshot shorter than what was already sent emits nothing: the wire cannot
  retract bytes, so a shrinking snapshot is silence, not a negative slice.
  """
  @spec unsent_suffix(t(), String.t()) :: {String.t(), t()}
  def unsent_suffix(%__MODULE__{turn: %{sent_len: sent_len} = turn} = session, cumulative)
      when is_binary(cumulative) do
    size = byte_size(cumulative)

    if size > sent_len do
      suffix = binary_part(cumulative, sent_len, size - sent_len)
      {suffix, %{session | turn: %{turn | sent_len: size}}}
    else
      {"", session}
    end
  end

  @doc """
  Restart the cumulative baseline for a new loop iteration.

  The loop's `text_delta` snapshots are cumulative *within an iteration*, so a
  turn that called a tool and resumed streams a fresh snapshot that starts over.
  Without this reset the suffix maths would slice the new snapshot at the old
  offset and put garbage on the wire.
  """
  @spec reset_stream(t()) :: t()
  def reset_stream(%__MODULE__{turn: turn} = session) when is_map(turn) do
    %{session | turn: %{turn | sent_len: 0}}
  end

  def reset_stream(%__MODULE__{turn: nil} = session), do: session

  @doc "Mint the tool-card id for a starting tool, remembering it for the finish update."
  @spec start_tool(t(), String.t()) :: {String.t(), t()}
  def start_tool(%__MODULE__{turn: turn} = session, name) when is_map(turn) and is_binary(name) do
    tool_seq = turn.tool_seq + 1
    tool_call_id = "t" <> Integer.to_string(tool_seq)
    turn = %{turn | tool_seq: tool_seq, tools: Map.put(turn.tools, name, tool_call_id)}

    {tool_call_id, %{session | turn: turn}}
  end

  @doc """
  Take back the tool-card id a start minted. `:error` when no start was seen —
  the update is dropped rather than invented, since a client cannot render an
  update for a card it never received.

  Keyed by tool name: the loop runs tool calls one at a time, so a repeat of the
  same name always follows its own finish.
  """
  @spec finish_tool(t(), String.t()) :: {:ok, String.t(), t()} | :error
  def finish_tool(%__MODULE__{turn: turn} = session, name)
      when is_map(turn) and is_binary(name) do
    case Map.pop(turn.tools, name) do
      {nil, _tools} -> :error
      {tool_call_id, tools} -> {:ok, tool_call_id, %{session | turn: %{turn | tools: tools}}}
    end
  end

  defp fold_block(%{"type" => "text", "text" => text}) when is_binary(text), do: {:ok, text}

  defp fold_block(%{"type" => "resource_link", "uri" => uri} = block) when is_binary(uri) do
    {:ok, "[resource: #{uri} (#{Map.get(block, "name", uri)})]"}
  end

  # A supported kind whose required field is missing is malformed, not
  # unsupported — the client sent a block this agent WOULD have accepted.
  defp fold_block(%{"type" => type}) when type in ["text", "resource_link"],
    do: {:error, :malformed_prompt}

  defp fold_block(%{"type" => type}) when is_binary(type),
    do: {:error, {:unsupported_block, type}}

  defp fold_block(_block), do: {:error, :malformed_prompt}

  defp join_blocks({:ok, reversed}) do
    folded = reversed |> Enum.reverse() |> Enum.join("\n\n")

    if String.trim(folded) == "", do: {:error, :empty_prompt}, else: {:ok, folded}
  end

  defp join_blocks({:error, _reason} = error), do: error
end
