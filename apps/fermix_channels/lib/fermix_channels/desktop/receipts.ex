defmodule FermixChannels.Desktop.Receipts do
  @moduledoc """
  A desktop's receipts of the actions it handled for its primary (M75 §11):
  `<home>/device/receipts.jsonl`, the one writer of that file.

  Each line records one invocation the desktop decided, whether it ran it or
  refused it: `{invocation_id, action, status, finished_at, args_sha256,
  result_sha256}`. Never the arguments or the output themselves, only their
  SHA-256. `invoke_status` is answered from them (`lookup/2`), so a result the
  primary lost in a reconnect is reconciled rather than run again, and the
  executor never runs an invocation it already holds a receipt for.

  The file is append-only between compactions and keeps the newest 1,000: a
  line is appended for each receipt, and once the file holds 100 lines more
  than that it is rewritten with the newest 1,000 (a private temp file renamed
  over it). Lookups answer from the newest 1,000 only, which this process holds
  in memory. A line that cannot be read (a write torn by a crash) is logged and
  skipped when the file is loaded. `device/` is device-local
  (`FermixCore.Home.DeviceLocal`) and protected from every agent tool
  (`Sandbox.PathPolicy`).
  """

  use GenServer

  require Logger

  @max 1_000
  @slack 100
  @fields ~w(invocation_id action status finished_at args_sha256 result_sha256)
  @statuses ~w(ok refused failed)

  @typedoc "One receipt, as a line holds it."
  @type receipt :: %{required(String.t()) => String.t()}

  @doc "How many receipts are kept."
  @spec max() :: pos_integer()
  def max, do: @max

  @doc "Where `home` keeps its receipts."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "",
    do: Path.join([home, "device", "receipts.jsonl"])

  @doc "Starts the writer for `:home`; `:name` names it (`nil` for none)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc false
  def child_spec(opts) when is_list(opts) do
    %{id: Keyword.get(opts, :name) || __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Records one receipt. `{:error, reason}` when the line could not be written."
  @spec record(GenServer.server(), receipt()) :: :ok | {:error, term()}
  def record(server, receipt) when is_map(receipt) do
    :ok = validate!(receipt)
    GenServer.call(server, {:record, receipt})
  end

  @doc "The receipts held for `invocation_ids`, in the order asked; ids without one are left out."
  @spec lookup(GenServer.server(), [String.t()]) :: [receipt()]
  def lookup(server, invocation_ids) when is_list(invocation_ids),
    do: GenServer.call(server, {:lookup, invocation_ids})

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:home) |> path()
    {receipts, lines} = load(path)
    state = %{path: path, order: :queue.from_list(receipts), by_id: index(receipts), lines: lines}
    {:ok, compact_if_due(state)}
  end

  @impl true
  def handle_call({:record, receipt}, _from, state) do
    case append(state.path, receipt) do
      :ok -> {:reply, :ok, state |> remember(receipt) |> compact_if_due()}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lookup, ids}, _from, state) do
    receipts = ids |> Enum.map(&Map.get(state.by_id, &1)) |> Enum.reject(&is_nil/1)
    {:reply, receipts, state}
  end

  # --- the file ------------------------------------------------------------

  defp load(path) do
    case File.read(path) do
      {:ok, contents} ->
        lines = String.split(contents, "\n", trim: true)
        receipts = lines |> Enum.flat_map(&parse_line(&1, path)) |> Enum.take(-@max)
        {receipts, length(lines)}

      {:error, :enoent} ->
        {[], 0}

      {:error, reason} ->
        raise "desktop receipts at #{path} could not be read: #{:file.format_error(reason)}"
    end
  end

  defp parse_line(line, path) do
    with {:ok, %{} = receipt} <- Jason.decode(line),
         :ok <- validate(receipt) do
      [Map.take(receipt, @fields)]
    else
      other ->
        Logger.error("desktop receipts at #{path}: an unreadable line skipped: #{inspect(other)}")
        []
    end
  end

  defp append(path, receipt) do
    with :ok <- ensure_dir(Path.dirname(path)),
         :ok <- File.write(path, [Jason.encode!(receipt), "\n"], [:append]) do
      File.chmod(path, 0o600)
    end
  end

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  defp remember(state, receipt) do
    id = Map.fetch!(receipt, "invocation_id")
    order = :queue.in(receipt, state.order)
    by_id = Map.put(state.by_id, id, receipt)
    trim(%{state | order: order, by_id: by_id, lines: state.lines + 1})
  end

  defp trim(state) do
    if :queue.len(state.order) > @max do
      {{:value, oldest}, order} = :queue.out(state.order)
      trim(%{state | order: order, by_id: forget(state.by_id, oldest)})
    else
      state
    end
  end

  # A newer receipt of the same id keeps its place in the index.
  defp forget(by_id, %{"invocation_id" => id} = oldest) do
    if Map.get(by_id, id) == oldest, do: Map.delete(by_id, id), else: by_id
  end

  defp compact_if_due(%{lines: lines} = state) when lines <= @max + @slack, do: state

  defp compact_if_due(state) do
    receipts = :queue.to_list(state.order)
    temp = state.path <> ".tmp"
    body = Enum.map(receipts, &[Jason.encode!(&1), "\n"])

    with :ok <- File.write(temp, body),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, state.path) do
      %{state | lines: length(receipts)}
    else
      {:error, reason} ->
        Logger.error("desktop receipts at #{state.path} not compacted: #{inspect(reason)}")
        _ = File.rm(temp)
        state
    end
  end

  defp index(receipts), do: Map.new(receipts, &{Map.fetch!(&1, "invocation_id"), &1})

  # --- shape ---------------------------------------------------------------

  defp validate!(receipt) do
    case validate(receipt) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "not a desktop receipt: #{inspect(reason)}"
    end
  end

  defp validate(receipt) do
    cond do
      not Enum.all?(@fields, &(is_binary(Map.get(receipt, &1)) and Map.get(receipt, &1) != "")) ->
        {:error, {:missing_fields, @fields -- Map.keys(receipt)}}

      Map.fetch!(receipt, "status") not in @statuses ->
        {:error, {:invalid_status, Map.fetch!(receipt, "status")}}

      true ->
        :ok
    end
  end
end
