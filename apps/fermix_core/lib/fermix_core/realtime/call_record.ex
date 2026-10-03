defmodule FermixCore.Realtime.CallRecord do
  @moduledoc """
  The durable record of one Live call (M56 §4.2): a `voice_calls` row the
  session opens when the call starts, writes as each task changes state, and
  closes when the call settles.

  The record is mechanical: what was asked, what became of it, how the call
  ended and what it cost. It survives a crash up to the last state written, and
  the boot sweep (`CallSweep`, through `sweep/2`) closes what a restart left
  open. `persist_transcripts` does not gate it; that setting governs verbatim
  captions only.

  A task is `{call_uuid, task_id, revision}`, `task_id` being the provider's
  delegation id. Its states are `created` and `running`, `detached` (a later
  stage: the task outlives its call), then one terminal state: `completed`,
  `failed`, `cancelled` or `timed_out`. Each task carries the request it ran
  with, capped at 2 KB from the front (its end is the ask), and the summary the
  session put on the wire. A private call's tasks carry no request (M56 §5).

  The functions building the record are pure. `open/3`, `write_tasks/2`,
  `close/5` and `sweep/2` are the writes, through `Memory.Repo`, and
  `recent_gists/2` the read a later call starts with; each answers
  `{:error, :disabled}` when memory is off, a configuration and not a failure.
  """

  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.LiveText
  alias FermixCore.Timeouts

  @states ~w(created running detached completed failed cancelled timed_out)
  @terminal_states ~w(completed failed cancelled timed_out)

  @request_max_bytes 2_048
  # A call is bounded by its max duration and a task takes seconds, so this is
  # generous; past it the oldest tasks give way to the newest.
  @max_tasks 64

  # Why a record the boot sweep closed ended, and why its unfinished tasks
  # failed.
  @restarted "daemon_restarted"

  @enforce_keys [:uuid, :engine]
  defstruct [:uuid, :engine, tasks: []]

  @typedoc "One task as stored: the JSON document's own string keys."
  @type task :: %{required(String.t()) => String.t() | pos_integer() | nil}
  @type t :: %__MODULE__{uuid: String.t(), engine: String.t(), tasks: [task()]}

  @doc "A record with no tasks yet, for the call `uuid` on `engine`."
  @spec new(String.t(), String.t()) :: t()
  def new(uuid, engine) when is_binary(uuid) and is_binary(engine) do
    %__MODULE__{uuid: uuid, engine: engine}
  end

  @doc """
  Moves a task to `state`, adding it the first time it is seen.

  `fields` may carry `:request` (capped at 2 KB, cut from the front the way
  `LiveText.tail/2` cuts the request a hand-off sends) and `:summary`; a field
  not given keeps what the task already holds.
  """
  @spec put_task(t(), String.t(), pos_integer(), String.t(), map()) :: t()
  def put_task(%__MODULE__{} = record, task_id, revision, state, fields \\ %{})
      when is_binary(task_id) and task_id != "" and is_integer(revision) and revision >= 1 and
             state in @states and is_map(fields) do
    key = {task_id, revision}

    case Enum.find_index(record.tasks, &(task_key(&1) == key)) do
      nil ->
        add_task(record, update_task(blank_task(task_id, revision), state, fields))

      index ->
        %{record | tasks: List.update_at(record.tasks, index, &update_task(&1, state, fields))}
    end
  end

  @doc "The Repo options a record write uses: a write that times out is an error, never an exit."
  @spec repo_opts(GenServer.server()) :: keyword()
  def repo_opts(repo), do: Repo.periodic_opts(repo, Timeouts.repo_call())

  @doc "Opens the record as the call starts."
  @spec open(t(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def open(%__MODULE__{} = record, %DateTime{} = started_at, repo_opts) do
    %{uuid: record.uuid, engine: record.engine, started_at: started_at, created_at: started_at}
    |> Repo.create_voice_call(repo_opts)
    |> written()
  end

  @doc "Writes the record's tasks as they stand."
  @spec write_tasks(t(), keyword()) :: :ok | {:error, term()}
  def write_tasks(%__MODULE__{} = record, repo_opts) do
    record.uuid
    |> Repo.update_voice_call_tasks(record.tasks, repo_opts)
    |> written()
  end

  @doc """
  Closes the record as the call settles: why it ended, the settled voice cost
  and its accounting, read from `usage` (`LiveLedger.usage_payload/1`, the
  payload of the final `usage` frame), and the final tasks.
  """
  @spec close(t(), atom(), map(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def close(%__MODULE__{} = record, end_reason, usage, %DateTime{} = ended_at, repo_opts)
      when is_atom(end_reason) and is_map(usage) do
    fields = %{
      ended_at: ended_at,
      end_reason: Atom.to_string(end_reason),
      voice_cost_cents: Map.fetch!(usage, :voice_cost_cents),
      accounting: Map.fetch!(usage, :accounting),
      tasks: record.tasks
    }

    record.uuid
    |> Repo.close_voice_call(fields, repo_opts)
    |> written()
  end

  @doc """
  The gists of the newest earlier calls that have one, newest first, at most
  `limit`: what a call in the chat's conversation starts with (M56 §4.3).
  A limit of 0 reads nothing.
  """
  @spec recent_gists(non_neg_integer(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def recent_gists(0, _repo_opts), do: {:ok, []}

  def recent_gists(limit, repo_opts) when is_integer(limit) and limit > 0,
    do: Repo.list_voice_call_gists(limit, repo_opts)

  @doc """
  Every task not in a terminal state, failed with the reason a restart gives:
  the process that ran it is gone, so it will never finish.
  """
  @spec fail_unfinished([task()]) :: [task()]
  def fail_unfinished(tasks) when is_list(tasks) do
    Enum.map(tasks, fn
      %{"state" => state} = task when state in @terminal_states -> task
      task -> Map.merge(task, %{"state" => "failed", "summary" => @restarted})
    end)
  end

  @doc """
  Closes every record a restart left open that started before `cutoff`: ended
  at `cutoff` as `daemon_restarted`, its bill unsettled (no cost, accounting
  `incomplete`), its unfinished tasks failed. Answers the UUIDs it closed, at
  most one page of `Repo.list_open_voice_calls/2`.
  """
  @spec sweep(DateTime.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def sweep(%DateTime{} = cutoff, repo_opts) do
    with {:ok, rows} <- Repo.list_open_voice_calls(cutoff, repo_opts) do
      close_stranded(rows, cutoff, repo_opts)
    end
  end

  defp close_stranded(rows, cutoff, repo_opts) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, closed} ->
      case Repo.close_voice_call(row.uuid, stranded(row, cutoff), repo_opts) do
        {:ok, _row} -> {:cont, {:ok, closed ++ [row.uuid]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stranded(row, cutoff) do
    %{
      ended_at: cutoff,
      end_reason: @restarted,
      voice_cost_cents: nil,
      accounting: "incomplete",
      tasks: fail_unfinished(row.tasks)
    }
  end

  defp blank_task(task_id, revision) do
    %{
      "task_id" => task_id,
      "revision" => revision,
      "state" => nil,
      "request" => nil,
      "summary" => nil
    }
  end

  defp update_task(task, state, fields) do
    task
    |> Map.put("state", state)
    |> put_field("request", request(Map.get(fields, :request)))
    |> put_field("summary", Map.get(fields, :summary))
  end

  defp put_field(task, _key, nil), do: task
  defp put_field(task, key, value) when is_binary(value), do: Map.put(task, key, value)

  defp request(nil), do: nil
  defp request(text) when is_binary(text), do: LiveText.tail(text, @request_max_bytes)

  defp add_task(record, task) do
    %{record | tasks: Enum.take(record.tasks ++ [task], -@max_tasks)}
  end

  defp task_key(task), do: {task["task_id"], task["revision"]}

  defp written({:ok, _row}), do: :ok
  defp written({:error, reason}), do: {:error, reason}
end
