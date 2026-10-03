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
  delegation id. Its states are `created` and `running`, `detached` (the task
  outlives its call, M56 §4.6), then one terminal state: `completed`,
  `failed`, `cancelled` or `timed_out`. Each task carries the request it ran
  with, capped at 2 KB from the front (its end is the ask), and the summary the
  session put on the wire. A private call's tasks carry no request (M56 §5). A
  detached task names where its result goes, `destination: "chat"`, the one
  destination there is.

  A detached task ends after its call's record closed: `settle_task/6` writes
  its terminal state into the record as stored, read and written back by the
  one process that owns the task once the session has exited. A daemon that
  died first leaves it `detached`, which the stage 1 sweep leaves alone (it
  closes only records left open, and a record a restart cut off mid-detach is
  closed with the task as it stands), and `sweep_detached/3` writes its done
  row and fails it at the next boot.

  A call in the chat owes the chat one row when it ends, and a gist when
  anything was said or handed off (M56 §4.2): the close writes what it owes
  with the settled bill, `record_gist/3` settles the gist once, and
  `write_row/3` writes the row once the gist has settled, rendered by
  `CallRow` from the record as stored, and marks it written. A daemon that
  died in between leaves both owed, and `sweep_rows/3`, run at boot, fails
  the gist no process will finish and writes the row from the task list. The
  row's writer is the companion channel, which Core never names, so both take
  the write as a function.

  The gist is not a memory fact: it is the call's record, read back by
  `recent_gists/2` for a later call and the chat's turns, with whether it was
  drawn from Computer History content (M56 §9).

  The functions building the record are pure. `open/3`, `write_tasks/2`,
  `close/6`, `record_gist/3`, `write_row/3`, `settle_task/6`, `sweep/2`,
  `sweep_rows/3` and `sweep_detached/3` are the writes, through
  `Memory.Repo`, and `recent_gists/2` the read; each answers
  `{:error, :disabled}` when memory is off, a configuration and not a
  failure.
  """

  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRow
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

  @typedoc """
  What a closing call owes the chat (M56 §4.2): its gist and its row (a call
  in the chat that said or handed off anything), its row alone (one that said
  nothing), or nothing (a private call, or one whose provider session never
  started).
  """
  @type owes :: :gist | :row | :nothing

  @typedoc "An earlier call's gist: when the call started (ISO 8601, UTC), its text and its mark."
  @type gist :: %{started_at: String.t(), gist: String.t(), tainted: boolean()}

  @typedoc """
  The write of a call's row: its `metadata.call` and its text in, the row's
  `server_seq` out (`Realtime.VoiceBridge.show/2`).
  """
  @type write_row :: (map(), String.t() -> {:ok, pos_integer()} | {:error, term()})

  @doc "A record with no tasks yet, for the call `uuid` on `engine`."
  @spec new(String.t(), String.t()) :: t()
  def new(uuid, engine) when is_binary(uuid) and is_binary(engine) do
    %__MODULE__{uuid: uuid, engine: engine}
  end

  @doc """
  Moves a task to `state`, adding it the first time it is seen.

  `fields` may carry `:request` (capped at 2 KB, cut from the front the way
  `LiveText.tail/2` cuts the request a hand-off sends), `:summary` and
  `:destination` (`"chat"`, a detached task's); a field not given keeps what
  the task already holds.
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
  payload of the final `usage` frame), the final tasks, and what the call owes
  the chat, in one write, so a crash after it never loses the row.
  """
  @spec close(t(), atom(), map(), DateTime.t(), keyword(), owes()) :: :ok | {:error, term()}
  def close(%__MODULE__{} = record, end_reason, usage, %DateTime{} = ended_at, repo_opts, owes)
      when is_atom(end_reason) and is_map(usage) and owes in [:gist, :row, :nothing] do
    fields =
      Map.merge(owed(owes), %{
        ended_at: ended_at,
        end_reason: Atom.to_string(end_reason),
        voice_cost_cents: Map.fetch!(usage, :voice_cost_cents),
        accounting: Map.fetch!(usage, :accounting),
        tasks: record.tasks
      })

    record.uuid
    |> Repo.close_voice_call(fields, repo_opts)
    |> written()
  end

  @doc """
  Settles the gist a close left pending: `{:ok, gist, tainted?}` writes it
  with its Computer History mark, `{:error, reason}` fails it.
  `{:error, :not_found}` when it was no longer pending.
  """
  @spec record_gist(String.t(), {:ok, String.t(), boolean()} | {:error, term()}, keyword()) ::
          :ok | {:error, term()}
  def record_gist(uuid, {:ok, gist, tainted?}, repo_opts)
      when is_binary(uuid) and is_binary(gist) and is_boolean(tainted?),
      do: uuid |> Repo.write_voice_call_gist(gist, tainted?, repo_opts) |> written()

  def record_gist(uuid, {:error, _reason}, repo_opts) when is_binary(uuid),
    do: uuid |> Repo.fail_voice_call_gist(repo_opts) |> written()

  @doc """
  Writes the call's row through `write` when the record owes it and its gist
  has settled, then marks it written, and answers the row's `server_seq`.
  `:not_owed` when the record owes no row (a private call, or one already
  written); `{:error, :gist_pending}` while the gist is still being made. A
  write that fails leaves the row owed, for the next boot.
  """
  @spec write_row(String.t(), write_row(), keyword()) ::
          {:ok, pos_integer()} | :not_owed | {:error, term()}
  def write_row(uuid, write, repo_opts) when is_binary(uuid) and is_function(write, 2) do
    with {:ok, record} <- Repo.get_voice_call(uuid, repo_opts),
         :owed <- row_owed(record),
         {call, text} = CallRow.ended(record),
         {:ok, server_seq} <- write.(call, text),
         {:ok, _marked} <- Repo.mark_voice_call_row_written(uuid, repo_opts) do
      {:ok, server_seq}
    end
  end

  defp row_owed(%{row_state: "row_pending", gist_status: "pending"}), do: {:error, :gist_pending}
  defp row_owed(%{row_state: "row_pending"}), do: :owed
  defp row_owed(_record), do: :not_owed

  @doc """
  The gists of the newest earlier calls that have one, newest first, at most
  `limit`: what a call in the chat's conversation starts with (M56 §4.3) and
  what the chat's own turns are told (§4.2). A limit of 0 reads nothing.
  """
  @spec recent_gists(non_neg_integer(), keyword()) :: {:ok, [gist()]} | {:error, term()}
  def recent_gists(0, _repo_opts), do: {:ok, []}

  def recent_gists(limit, repo_opts) when is_integer(limit) and limit > 0,
    do: Repo.list_voice_call_gists(limit, repo_opts)

  @doc """
  Every task not in a terminal state, failed with the reason a restart gives:
  the process that ran it is gone, so it will never finish. A `detached` task
  is left as it is: it is the chat's, and the boot pass that writes its row
  fails it (`sweep_detached/3`).
  """
  @spec fail_unfinished([task()]) :: [task()]
  def fail_unfinished(tasks) when is_list(tasks) do
    Enum.map(tasks, fn
      %{"state" => state} = task when state in @terminal_states -> task
      %{"state" => "detached"} = task -> task
      task -> restarted(task)
    end)
  end

  @doc """
  Writes the terminal state of one task into the record as stored: a task
  that outlived its call ends after the record closed (M56 §4.6).
  `{:error, :not_found}` when there is no such record.
  """
  @spec settle_task(
          String.t(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t() | nil,
          keyword()
        ) ::
          :ok | {:error, term()}
  def settle_task(uuid, task_id, revision, state, summary, repo_opts)
      when is_binary(uuid) and state in @terminal_states and
             (is_nil(summary) or is_binary(summary)) do
    with {:ok, row} <- Repo.get_voice_call(uuid, repo_opts) do
      %__MODULE__{uuid: uuid, engine: row.engine, tasks: row.tasks}
      |> put_task(task_id, revision, state, %{summary: summary})
      |> write_tasks(repo_opts)
    end
  end

  @doc """
  Ends every task a restart left `detached` in a closed record started before
  `cutoff` (M56 §4.6, §8): its done row first, written through `write` and
  keyed so a repeat finds it, then the task failed with `daemon_restarted`.
  Answers the UUIDs it settled, at most one page of
  `Repo.list_detached_voice_calls/2`; the first failure stops the pass, and
  the next boot settles the rest.
  """
  @spec sweep_detached(DateTime.t(), write_row(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def sweep_detached(%DateTime{} = cutoff, write, repo_opts) when is_function(write, 2) do
    with {:ok, rows} <- Repo.list_detached_voice_calls(cutoff, repo_opts) do
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, settled} ->
        case settle_detached(row, write, repo_opts) do
          :ok -> {:cont, {:ok, settled ++ [row.uuid]}}
          {:error, reason} -> {:halt, {:error, {row.uuid, reason}}}
        end
      end)
    end
  end

  defp settle_detached(row, write, repo_opts) do
    detached = Enum.filter(row.tasks, &(&1["state"] == "detached"))

    with :ok <- write_restarted_rows(row.uuid, detached, write) do
      tasks = Enum.map(row.tasks, &restarted_if_detached/1)
      row.uuid |> Repo.update_voice_call_tasks(tasks, repo_opts) |> written()
    end
  end

  defp write_restarted_rows(uuid, tasks, write) do
    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      {call, text} = CallRow.task_done(uuid, task["task_id"], task["revision"], :restarted)

      case write.(call, text) do
        {:ok, _server_seq} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp restarted_if_detached(%{"state" => "detached"} = task), do: restarted(task)
  defp restarted_if_detached(task), do: task

  defp restarted(task), do: Map.merge(task, %{"state" => "failed", "summary" => @restarted})

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

  @doc """
  Writes every row a call owed when the daemon died, of the calls started
  before `cutoff` (M56 §4.2, §8): a gist still pending is failed first, since
  the process making it is gone, and the row then carries the task list.
  Answers the UUIDs whose rows it wrote, at most one page of
  `Repo.list_owed_voice_call_rows/2`; the first failure stops the pass, and
  the next boot writes the rest.
  """
  @spec sweep_rows(DateTime.t(), write_row(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def sweep_rows(%DateTime{} = cutoff, write, repo_opts) when is_function(write, 2) do
    with {:ok, rows} <- Repo.list_owed_voice_call_rows(cutoff, repo_opts) do
      write_owed(rows, write, repo_opts)
    end
  end

  defp write_owed(rows, write, repo_opts) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, swept} ->
      case owed_row(row, write, repo_opts) do
        {:ok, _server_seq} -> {:cont, {:ok, swept ++ [row.uuid]}}
        {:error, reason} -> {:halt, {:error, {row.uuid, reason}}}
      end
    end)
  end

  defp owed_row(%{gist_status: "pending", uuid: uuid}, write, repo_opts) do
    with :ok <- record_gist(uuid, {:error, :daemon_restarted}, repo_opts) do
      write_row(uuid, write, repo_opts)
    end
  end

  defp owed_row(%{uuid: uuid}, write, repo_opts), do: write_row(uuid, write, repo_opts)

  defp close_stranded(rows, cutoff, repo_opts) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, closed} ->
      case Repo.close_voice_call(row.uuid, stranded(row, cutoff), repo_opts) do
        {:ok, _row} -> {:cont, {:ok, closed ++ [row.uuid]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A call cut off mid-call owes no row: its end is not known, only that the
  # daemon restarted after it.
  defp stranded(row, cutoff) do
    Map.merge(owed(:nothing), %{
      ended_at: cutoff,
      end_reason: @restarted,
      voice_cost_cents: nil,
      accounting: "incomplete",
      tasks: fail_unfinished(row.tasks)
    })
  end

  defp owed(:gist), do: %{gist_status: "pending", row_state: "row_pending"}
  defp owed(:row), do: %{gist_status: "none", row_state: "row_pending"}
  defp owed(:nothing), do: %{gist_status: "none", row_state: "none"}

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
    |> put_field("destination", destination(Map.get(fields, :destination)))
  end

  # The one place a detached task's result goes (M56 §4.6).
  defp destination(nil), do: nil
  defp destination("chat"), do: "chat"

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
