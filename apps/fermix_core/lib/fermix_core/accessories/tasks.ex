defmodule FermixCore.Accessories.Tasks do
  @moduledoc """
  The accessory's task reactions from every voice engine (M91 D21;
  `priv/accessory/PROTOCOL.md`, *Tasks*): what the link sends as
  `task.event {task, revision, status, in_chat}`, so the firmware never learns
  which engine runs and one reaction table holds for all three.

    * A GPT-Live or Grok `task` frame names its delegation: `task` is its
      `delegation_id`, `revision` its revision, `status` its status
      (`pending` is sent as `running`), and `in_chat` whether it names a chat
      row (`server_seq`). The frame that detaches a task as its call ends is
      not sent: the call is over.
    * OpenAI Realtime's `tool_event`s carry no ID (`priv/realtime/PROTOCOL.md`,
      *Server events*): its voice model calls tools itself, several at once, so
      the accessory sees one task per tool batch. The first `running` while no
      batch is open starts task `rt:<n>` (call-local, revision 1) as
      `running`, later calls join it, and it settles when its last open call
      settles: `completed` when every call completed, `failed` when any
      errored. A provider reconnect abandons every running call with no further
      `tool_event`, so a reconnect while a batch is open settles it
      `cancelled`. `in_chat` is always `false`: an OpenAI Realtime call writes
      no chat row. A `completed` or `error` with no open batch is a contract
      fault, counted here, and never opens a batch.

  Tool names and error reasons stay on the host: no event carries them. Pure.
  """

  @max_task_bytes 64
  @max_revision 4_294_967_295
  @task_statuses %{
    "pending" => "running",
    "running" => "running",
    "completed" => "completed",
    "failed" => "failed",
    "cancelled" => "cancelled"
  }

  defstruct batch: 0, open: 0, failed?: false, faults: 0

  @typedoc """
  The OpenAI Realtime batch a call is in: how many batches it has started,
  how many calls the open one still waits on, whether one of them errored,
  and the unmatched settles counted.
  """
  @type t :: %__MODULE__{
          batch: non_neg_integer(),
          open: non_neg_integer(),
          failed?: boolean(),
          faults: non_neg_integer()
        }

  @typedoc "One `task.event`'s own fields; the link adds `type`, `gen` and `stream`."
  @type event :: %{
          task: String.t(),
          revision: pos_integer(),
          status: String.t(),
          in_chat: boolean()
        }

  @doc "A call's batch state before its first tool call."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  The `task.event` for a task engine's `task` frame, `:skip` for the frame
  that detaches a task at the end of a call, or `{:error, field}` for a frame
  the accessory link cannot carry (the field it breaks).
  """
  @spec from_task_frame(map()) :: {:ok, event()} | :skip | {:error, atom()}
  def from_task_frame(%{type: "task", detached: true}), do: :skip

  def from_task_frame(
        %{type: "task", delegation_id: id, revision: revision, status: status} = frame
      ) do
    with :ok <- task_id(id),
         :ok <- revision(revision),
         {:ok, sent} <- status(status) do
      {:ok, %{task: id, revision: revision, status: sent, in_chat: in_chat?(frame)}}
    end
  end

  def from_task_frame(%{type: "task"}), do: {:error, :fields}

  @doc """
  One OpenAI Realtime `tool_event`: the `task.event`s it settles or starts,
  or `{:fault, :unmatched_settle, state}` for a settle with no open batch,
  which is counted and opens nothing. A status outside the three it has is
  `{:fault, :unknown_status, state}`, counted the same way.
  """
  @spec tool_event(t(), map()) :: {:ok, [event()], t()} | {:fault, atom(), t()}
  def tool_event(%__MODULE__{} = state, %{type: "tool_event", status: "running"}),
    do: start_or_join(state)

  def tool_event(%__MODULE__{open: 0} = state, %{type: "tool_event", status: status})
      when status in ["completed", "error"],
      do: {:fault, :unmatched_settle, count_fault(state)}

  def tool_event(%__MODULE__{} = state, %{type: "tool_event", status: "completed"}),
    do: settle_one(state, false)

  def tool_event(%__MODULE__{} = state, %{type: "tool_event", status: "error"}),
    do: settle_one(state, true)

  def tool_event(%__MODULE__{} = state, %{type: "tool_event"}),
    do: {:fault, :unknown_status, count_fault(state)}

  @doc """
  The provider session reconnected: an open batch's calls were abandoned with
  no further event, so it settles `cancelled`; with none open, nothing.
  """
  @spec reconnect(t()) :: {[event()], t()}
  def reconnect(%__MODULE__{open: 0} = state), do: {[], state}

  def reconnect(%__MODULE__{} = state),
    do: {[batch_event(state, "cancelled")], %{state | open: 0, failed?: false}}

  @doc "The unmatched settles this call counted."
  @spec faults(t()) :: non_neg_integer()
  def faults(%__MODULE__{faults: faults}), do: faults

  defp start_or_join(%__MODULE__{open: 0} = state) do
    started = %{state | batch: state.batch + 1, open: 1, failed?: false}
    {:ok, [batch_event(started, "running")], started}
  end

  defp start_or_join(%__MODULE__{} = state), do: {:ok, [], %{state | open: state.open + 1}}

  defp settle_one(state, errored?) do
    state = %{state | open: state.open - 1, failed?: state.failed? or errored?}

    if state.open == 0,
      do: {:ok, [batch_event(state, settled_status(state))], %{state | failed?: false}},
      else: {:ok, [], state}
  end

  defp settled_status(%__MODULE__{failed?: true}), do: "failed"
  defp settled_status(%__MODULE__{failed?: false}), do: "completed"

  defp batch_event(state, status),
    do: %{task: "rt:#{state.batch}", revision: 1, status: status, in_chat: false}

  defp count_fault(state), do: %{state | faults: state.faults + 1}

  defp in_chat?(frame), do: is_integer(Map.get(frame, :server_seq))

  # The accessory's `task` is text of at most 64 printable characters with no
  # space, and its revision a u32: a delegation outside them cannot be named.
  defp task_id(id) when is_binary(id) and byte_size(id) in 1..@max_task_bytes//1 do
    if printable?(id), do: :ok, else: {:error, :delegation_id}
  end

  defp task_id(_id), do: {:error, :delegation_id}

  defp revision(revision) when is_integer(revision) and revision in 1..@max_revision//1, do: :ok
  defp revision(_revision), do: {:error, :revision}

  defp status(status) do
    case Map.fetch(@task_statuses, status) do
      {:ok, sent} -> {:ok, sent}
      :error -> {:error, :status}
    end
  end

  defp printable?(<<char, rest::binary>>) when char in 0x21..0x7E, do: printable?(rest)
  defp printable?(<<>>), do: true
  defp printable?(_other), do: false
end
