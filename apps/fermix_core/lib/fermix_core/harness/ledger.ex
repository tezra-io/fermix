defmodule FermixCore.Harness.Ledger do
  @moduledoc """
  Public face over the `harness_runs` table.

  The ledger owns run-id generation and reads `FermixCore.Harness.Config`, then
  delegates every persistence operation to `FermixCore.Memory.Repo` (the single
  serialized SQLite owner). Keeping config reads here leaves the Repo
  config-free: admission passes the current `max_active` in explicitly.

  A run id is `"hr_"` followed by 12 lowercase hex characters (6 random bytes).
  Uniqueness is by the table's primary key; a caller may pin an id in `attrs`
  (reconciliation, tests) and the ledger keeps it.
  """

  alias FermixCore.Harness.Config
  alias FermixCore.Memory.Repo

  @id_prefix "hr_"
  @id_bytes 6

  # A run enters the ledger active (holding its locks + capacity) and leaves
  # terminal (releasing them). These two classes bound the status transitions
  # this public face accepts, so a caller can never admit an already-terminal
  # run nor "terminalize" a run to another active status (which would leave it
  # holding locks with completed_at set — §12.1).
  @admit_statuses ~w(starting submitting)
  @terminal_statuses ~w(completed failed blocked cancelled interrupted)

  @doc """
  Generates a fresh run id: `"hr_"` + 12 lowercase hex characters.
  """
  @spec generate_id() :: String.t()
  def generate_id do
    @id_prefix <> Base.encode16(:crypto.strong_rand_bytes(@id_bytes), case: :lower)
  end

  @doc """
  Atomically admits a run, assigning a fresh id when `attrs` has none.

  Reads `Config.max_active/0` and passes it to the Repo's `BEGIN IMMEDIATE`
  admission. Returns `{:error, :max_active}` at capacity or
  `{:error, {:workspace_locked, root}}` when an active run already holds a lock
  root.
  """
  @spec admit(map(), keyword()) ::
          {:ok, map()}
          | {:error,
             :max_active
             | {:workspace_locked, String.t()}
             | {:invalid_admit_status, term()}
             | term()}
  def admit(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with :ok <- ensure_admit_status(attrs) do
      attrs
      |> Map.put_new_lazy(:id, &generate_id/0)
      |> Repo.admit_harness_run(Config.max_active(), opts)
    end
  end

  @doc """
  Terminalizes a run, releasing its workspace locks. `fields` carries the
  terminal columns (`reason`, `exit_code`, `usage`, `diagnostics_tail`, …);
  `completed_at` is set automatically unless provided.
  """
  @spec terminalize(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()}
          | {:error,
             :already_terminal | :not_found | {:invalid_terminal_status, String.t()} | term()}
  def terminalize(id, status, fields \\ %{}, opts \\ [])
      when is_binary(id) and is_binary(status) and is_map(fields) and is_list(opts) do
    if status in @terminal_statuses do
      Repo.terminalize_harness_run(id, status, fields, opts)
    else
      {:error, {:invalid_terminal_status, status}}
    end
  end

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def get(id, opts \\ []) when is_binary(id) and is_list(opts) do
    Repo.get_harness_run(id, opts)
  end

  @spec list(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(filters \\ %{}, opts \\ []) when is_map(filters) and is_list(opts) do
    Repo.list_harness_runs(filters, opts)
  end

  @spec active_runs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def active_runs(opts \\ []) when is_list(opts) do
    Repo.active_harness_runs(opts)
  end

  @spec pending_deliveries(DateTime.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def pending_deliveries(%DateTime{} = now, opts \\ []) when is_list(opts) do
    Repo.pending_harness_deliveries(now, opts)
  end

  @doc """
  Records the vendor session id once the harness reports it (resume handle).
  """
  @spec record_session(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def record_session(id, vendor_session_id, opts \\ [])
      when is_binary(id) and is_binary(vendor_session_id) and is_list(opts) do
    Repo.update_harness_run(id, %{vendor_session_id: vendor_session_id}, opts)
  end

  @doc """
  Flips a local run from `starting` to `running` on its first stream event (a
  guarded transition — a terminal or already-`running` row is left untouched, its
  current state returned). `running` is the only non-terminal transition after
  admission; the terminal writer stays the single terminal authority.
  """
  @spec mark_running(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def mark_running(id, opts \\ []) when is_binary(id) and is_list(opts) do
    Repo.mark_harness_run_running(id, opts)
  end

  @doc """
  Records throttled material progress (timestamps, poll schedule). Throttling is
  the caller's concern; the ledger stays dumb and writes what it is given.
  """
  @spec record_progress(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def record_progress(id, fields, opts \\ [])
      when is_binary(id) and is_map(fields) and map_size(fields) > 0 and is_list(opts) do
    Repo.update_harness_run(id, fields, opts)
  end

  @doc """
  Promotes a cloud run `submitting` → `polling`, persisting the poll schedule
  (`task_id`, `task_url`, `next_poll_at`, `poll_deadline`) atomically. `polling` is
  the cloud analogue of `mark_running/2`'s `running`: an active status after
  admission, written through a guarded transition so the terminal writer stays the
  single terminal authority.
  """
  @spec mark_polling(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def mark_polling(id, fields, opts \\ [])
      when is_binary(id) and is_map(fields) and map_size(fields) > 0 and is_list(opts) do
    Repo.promote_harness_run_polling(id, fields, opts)
  end

  @doc """
  Updates durable delivery state (`delivery_status`, `delivery_attempts`,
  `next_delivery_at`, `last_delivery_error`, `delivered_at`).
  """
  @spec mark_delivery(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def mark_delivery(id, fields, opts \\ [])
      when is_binary(id) and is_map(fields) and map_size(fields) > 0 and is_list(opts) do
    Repo.update_harness_run(id, fields, opts)
  end

  defp ensure_admit_status(attrs) do
    case Map.get(attrs, :status) do
      status when status in @admit_statuses -> :ok
      other -> {:error, {:invalid_admit_status, other}}
    end
  end
end
