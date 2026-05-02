defmodule FermixCore.Memory.ConversationWriteBenchmark do
  @moduledoc """
  Measures the synchronous ConversationStore message enqueue path.
  """

  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo

  @type stats :: %{
          avg_us: float(),
          p50_us: non_neg_integer(),
          p95_us: non_neg_integer(),
          p99_us: non_neg_integer(),
          max_us: non_neg_integer()
        }

  @type result :: %{
          iterations: pos_integer(),
          warmup: non_neg_integer(),
          message_bytes: pos_integer(),
          database_path: String.t(),
          in_memory: stats(),
          durable: stats(),
          overhead: stats()
        }

  @default_iterations 500
  @default_warmup 50
  @default_message_bytes 256

  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    iterations = positive_integer(opts, :iterations, @default_iterations)
    warmup = non_negative_integer(opts, :warmup, @default_warmup)
    message_bytes = positive_integer(opts, :message_bytes, @default_message_bytes)
    database_path = Keyword.get(opts, :database_path, default_database_path())

    with {:ok, pids} <- start_servers(database_path) do
      try do
        {:ok,
         measure(
           pids.memory_store,
           pids.durable_store,
           iterations,
           warmup,
           message_bytes,
           database_path
         )}
      after
        stop_servers(pids)
        maybe_remove_database(database_path, Keyword.get(opts, :keep_database, false))
      end
    end
  end

  defp measure(memory_store, durable_store, iterations, warmup, message_bytes, database_path) do
    content = String.duplicate("x", message_bytes)

    warm_up(memory_store, warmup, content)
    warm_up(durable_store, warmup, content)

    memory_samples = collect_samples(memory_store, iterations, content, "memory")
    durable_samples = collect_samples(durable_store, iterations, content, "durable")

    %{
      iterations: iterations,
      warmup: warmup,
      message_bytes: message_bytes,
      database_path: database_path,
      in_memory: stats(memory_samples),
      durable: stats(durable_samples),
      overhead: stats(overhead_samples(memory_samples, durable_samples))
    }
  end

  defp start_servers(database_path) do
    unique = System.unique_integer([:positive])
    repo = :"conversation_write_benchmark_repo_#{unique}"
    memory_store = :"conversation_write_benchmark_memory_#{unique}"
    durable_store = :"conversation_write_benchmark_durable_#{unique}"

    case Repo.start_link(name: repo, enabled: true, database_path: database_path) do
      {:ok, repo_pid} ->
        start_stores(repo, repo_pid, memory_store, durable_store)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_stores(repo, repo_pid, memory_store, durable_store) do
    case ConversationStore.start_link(name: memory_store, repo: nil) do
      {:ok, memory_pid} ->
        start_durable_store(repo, repo_pid, memory_store, memory_pid, durable_store)

      {:error, reason} ->
        stop_server(repo_pid)
        {:error, reason}
    end
  end

  defp start_durable_store(repo, repo_pid, memory_store, memory_pid, durable_store) do
    case ConversationStore.start_link(name: durable_store, repo: repo) do
      {:ok, durable_pid} ->
        {:ok,
         %{
           repo: repo_pid,
           memory_store: memory_store,
           memory_pid: memory_pid,
           durable_store: durable_store,
           durable_pid: durable_pid
         }}

      {:error, reason} ->
        stop_server(memory_pid)
        stop_server(repo_pid)
        {:error, reason}
    end
  end

  defp stop_servers(pids) do
    Enum.each([pids.memory_pid, pids.durable_pid, pids.repo], &stop_server/1)
  end

  defp stop_server(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp warm_up(_store, 0, _content), do: :ok

  defp warm_up(store, count, content) do
    Enum.each(1..count, fn index ->
      write_message(store, index, content, "warmup")
    end)
  end

  defp collect_samples(store, iterations, content, label) do
    Enum.map(1..iterations, fn index ->
      timed(fn -> write_message(store, index, content, label) end)
    end)
  end

  defp write_message(store, index, content, label) do
    key = {"benchmark", label, :root}
    ConversationStore.add_message(key, "user", "#{content}-#{index}", server: store)
  end

  defp timed(fun) do
    start = System.monotonic_time()
    :ok = fun.()

    System.monotonic_time()
    |> Kernel.-(start)
    |> System.convert_time_unit(:native, :microsecond)
  end

  defp stats(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)

    %{
      avg_us: Enum.sum(sorted) / count,
      p50_us: percentile(sorted, 50),
      p95_us: percentile(sorted, 95),
      p99_us: percentile(sorted, 99),
      max_us: List.last(sorted)
    }
  end

  defp percentile(sorted, percentile) do
    count = length(sorted)
    index = ceil(count * percentile / 100) - 1
    Enum.at(sorted, max(index, 0))
  end

  defp overhead_samples(memory_samples, durable_samples) do
    memory_samples
    |> Enum.zip(durable_samples)
    |> Enum.map(fn {memory_us, durable_us} -> max(durable_us - memory_us, 0) end)
  end

  defp positive_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      value -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
    end
  end

  defp non_negative_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 ->
        value

      value ->
        raise ArgumentError, "#{key} must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp default_database_path do
    Path.join(
      System.tmp_dir!(),
      "fermix-conversation-write-benchmark-#{System.unique_integer([:positive])}.db"
    )
  end

  defp maybe_remove_database(_database_path, true), do: :ok

  defp maybe_remove_database(database_path, false) do
    Enum.each([database_path, "#{database_path}-wal", "#{database_path}-shm"], &File.rm/1)
  end
end
