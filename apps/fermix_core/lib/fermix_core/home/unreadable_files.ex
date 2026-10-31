defmodule FermixCore.Home.UnreadableFiles do
  @moduledoc """
  Which of the things `home.status` reads on every poll cannot be read now
  (M75 lean v1 §7): the provisioner's ledger (`Provision.Ledger.state/3`),
  the settings its summary reads for what stops after a move
  (`MoveReadiness.stays_here/3`), the primary's disk
  (`Management.Home.status/1`), the last review of the move and each copy a
  desktop stores (`Management.HomeSummary.gather/5`). The apps poll
  `home.status`, so one that stays unreadable would log on every poll. Its
  reader logs instead once when the failure starts and once when it ends,
  with the reads that failed in between counted (as `FermixCore.Trace` logs
  a failure to write), and every answer still says what is wrong.

  `log_read/4` is what a reader calls with the result of each read: it
  logs the start and the end, and nothing between. What was read is named
  by its subject (a path, or "the disk of <home>"), which keys the memory.
  `transition/3` is the pure step it rests on: a subject's first failed read
  is `:started`, another
  is `:failing`, the first good read after them `{:ended, failed_reads}`,
  any other `:fine`. A failure is one stretch whatever its reason.

  It runs in every role's tree (`FermixCore.Application`), before anything
  that answers `home.status`. A reader given no memory (`nil`: a verb run
  with no engine tree, whose one read is its first) logs every failure.
  """

  use GenServer

  require Logger

  @type result :: :ok | {:ok, term()} | {:error, term()}
  @type change :: :started | :failing | {:ended, pos_integer()} | :fine
  @type failing :: %{String.t() => pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Logs what `result`, a read of `subject`, changed: an error naming
  `subject` and the reason when a failure starts, and a warning with how many
  reads failed when it ends. `what` begins each line (the reader's own
  prefix); `server` is the memory, or nil for none.
  """
  @spec log_read(String.t(), String.t(), result(), GenServer.server() | nil) :: :ok
  def log_read(subject, what, result, server) when is_binary(subject) and is_binary(what) do
    case note(subject, result, server) do
      :started ->
        {:error, reason} = result

        Logger.error(
          "#{what}: #{subject} could not be read: #{inspect(reason)}; " <>
            "logged again only once it reads"
        )

      {:ended, failed} ->
        Logger.warning("#{what}: #{subject} reads again after #{reads(failed)}")

      _quiet ->
        :ok
    end
  end

  @doc "The change one read of `file` (its subject) makes to `failing`, and what fails after it."
  @spec transition(failing(), String.t(), result()) :: {change(), failing()}
  def transition(failing, file, {:error, _reason}) when is_map(failing) and is_binary(file) do
    case failing do
      %{^file => failed} -> {:failing, %{failing | file => failed + 1}}
      _first -> {:started, Map.put(failing, file, 1)}
    end
  end

  def transition(failing, file, :ok) when is_map(failing) and is_binary(file),
    do: read(failing, file)

  def transition(failing, file, {:ok, _read}) when is_map(failing) and is_binary(file),
    do: read(failing, file)

  defp read(failing, file) do
    case Map.pop(failing, file) do
      {nil, failing} -> {:fine, failing}
      {failed, failing} -> {{:ended, failed}, failing}
    end
  end

  defp note(file, result, nil), do: elem(transition(%{}, file, result), 0)
  defp note(file, result, server), do: GenServer.call(server, {:note, file, outcome(result)})

  # Only whether it failed crosses to the memory, never what was read.
  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome(_read), do: :ok

  defp reads(1), do: "1 failed read"
  defp reads(count), do: "#{count} failed reads"

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:note, file, result}, _from, failing) do
    {change, failing} = transition(failing, file, result)
    {:reply, change, failing}
  end
end
