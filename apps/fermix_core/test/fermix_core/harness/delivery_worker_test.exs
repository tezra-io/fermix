defmodule FermixCore.Harness.DeliveryWorkerTest do
  # async: false — establishes a known `[fermix_core.harness]` app-env baseline
  # (admission capacity + delivery caps) and restores it on exit
  # (hermetic-config discipline).
  use ExUnit.Case, async: false

  alias FermixCore.Harness.DeliveryWorker
  alias FermixCore.Harness.Ledger
  alias FermixCore.Memory.Repo

  @now ~U[2026-07-20 12:00:00Z]

  defmodule OkAdapter do
    def send_message(_destination, _text, _opts), do: :ok
  end

  defmodule FailingAdapter do
    def send_message(_destination, _text, _opts), do: {:error, :permanent}
  end

  defmodule RateLimitedAdapter do
    def send_message(_destination, _text, _opts), do: {:error, {:rate_limited, 300_000}}
  end

  setup do
    prev_harness = Application.get_env(:fermix_core, :harness)

    Application.put_env(:fermix_core, :harness,
      max_active: 10,
      delivery_max_attempts: 20,
      delivery_max_age_hours: 24
    )

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-harness-worker-#{unique}.db")
    repo = :"harness_worker_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      case prev_harness do
        nil -> Application.delete_env(:fermix_core, :harness)
        value -> Application.put_env(:fermix_core, :harness, value)
      end

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo}
  end

  defp pending_row(repo, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          vendor: "codex",
          rail: "local",
          status: "starting",
          cwd: "/repo",
          worktree_root: "/repo",
          lock_roots: ["/repo/#{System.unique_integer([:positive])}"],
          artifacts_dir: "/tmp/none",
          origin_kind: "chat",
          origin_session_id: "telegram:123:root",
          delivery_mode: "channel",
          platform: "telegram",
          destination: "123",
          created_at: @now
        },
        overrides
      )

    {:ok, admitted} = Ledger.admit(attrs, server: repo)
    {:ok, terminal} = Ledger.terminalize(admitted.id, "failed", %{reason: "exit_1"}, server: repo)
    terminal
  end

  defp start_worker(repo, opts) do
    name = :"harness_worker_#{System.unique_integer([:positive])}"
    {adapter, opts} = Keyword.pop(opts, :adapter)

    start_opts =
      [
        name: name,
        repo: repo,
        timer_enabled: false,
        now_fn: fn -> @now end,
        delivery_opts: [adapter: adapter]
      ]
      |> Keyword.merge(opts)

    start_supervised!(%{
      id: name,
      start: {DeliveryWorker, :start_link, [start_opts]}
    })
  end

  # `send/2` then a `:sys.get_state/1` barrier: messages are processed FIFO, so
  # the state read blocks until the drained `:tick` has fully run (no sleeps).
  defp tick(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
    :ok
  end

  test "records a backoff and increments attempts on a send failure", %{repo: repo} do
    row = pending_row(repo)
    worker = start_worker(repo, adapter: FailingAdapter, max_attempts: 5)

    :ok = tick(worker)

    {:ok, updated} = Ledger.get(row.id, server: repo)
    assert updated.delivery_status == "pending"
    assert updated.delivery_attempts == 1
    assert DateTime.diff(updated.next_delivery_at, @now, :second) == 30
    assert updated.last_delivery_error =~ "permanent"
  end

  test "dead-letters once the attempt ceiling is reached", %{repo: repo} do
    row = pending_row(repo, %{delivery_attempts: 2})
    worker = start_worker(repo, adapter: FailingAdapter, max_attempts: 3)

    :ok = tick(worker)

    {:ok, updated} = Ledger.get(row.id, server: repo)
    assert updated.delivery_status == "dead_letter"
    assert updated.last_delivery_error =~ "permanent"
  end

  test "dead-letters a row older than the max age even below the attempt ceiling", %{repo: repo} do
    row = pending_row(repo, %{created_at: DateTime.add(@now, -48, :hour)})
    worker = start_worker(repo, adapter: FailingAdapter, max_attempts: 20, max_age_hours: 24)

    :ok = tick(worker)

    {:ok, updated} = Ledger.get(row.id, server: repo)
    assert updated.delivery_status == "dead_letter"
  end

  test "honors a rate-limited retry-after as the backoff floor", %{repo: repo} do
    row = pending_row(repo)
    worker = start_worker(repo, adapter: RateLimitedAdapter, max_attempts: 5)

    :ok = tick(worker)

    {:ok, updated} = Ledger.get(row.id, server: repo)
    assert updated.delivery_status == "pending"
    assert updated.delivery_attempts == 1
    # 300_000ms retry-after beats the 30s attempt-1 backoff.
    assert DateTime.diff(updated.next_delivery_at, @now, :second) == 300
  end

  test "marks the row delivered on a successful send", %{repo: repo} do
    row = pending_row(repo)
    worker = start_worker(repo, adapter: OkAdapter)

    :ok = tick(worker)

    {:ok, updated} = Ledger.get(row.id, server: repo)
    assert updated.delivery_status == "delivered"
    assert %DateTime{} = updated.delivered_at
  end

  test "does not exceed the per-tick row cap", %{repo: repo} do
    rows = for _ <- 1..3, do: pending_row(repo)
    worker = start_worker(repo, adapter: OkAdapter, max_rows_per_tick: 2)

    :ok = tick(worker)

    statuses =
      Enum.map(rows, fn row ->
        {:ok, updated} = Ledger.get(row.id, server: repo)
        updated.delivery_status
      end)

    assert Enum.count(statuses, &(&1 == "delivered")) == 2
    assert Enum.count(statuses, &(&1 == "pending")) == 1
  end

  test "drains the outbox even when the harness is config-disabled", %{repo: repo} do
    # Turning the harness off gates NEW admissions, never in-flight deliveries:
    # a pending row must still be delivered (the at-least-once guarantee), so the
    # drain ignores Config.enabled? — only the timer is a seam.
    Application.put_env(:fermix_core, :harness, enabled: false, delivery_max_attempts: 20)

    row = pending_row(repo)
    worker = start_worker(repo, adapter: OkAdapter)

    :ok = tick(worker)

    {:ok, updated} = Ledger.get(row.id, server: repo)
    assert updated.delivery_status == "delivered"
  end
end
