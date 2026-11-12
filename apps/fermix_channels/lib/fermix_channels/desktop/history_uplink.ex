defmodule FermixChannels.Desktop.HistoryUplink do
  @moduledoc """
  How a computer sends its home a finished sitting of computer history (M97
  §6.1, §8.1): one `history.submit` invocation toward the home, its arguments
  the sitting (`FermixCore.ComputerHistory.Sittings`), sent through this
  computer's relay in the bulk lane (`Mobile.Lanes`), and its `invoke_result`
  waited for here, in the process that sent it. Its report of its recorder
  (`FermixCore.ComputerHistory.Report`, §8.5) goes the same way with
  `history.report`, in the interactive lane, from the same sending cycle.

  - Only while this computer offers its history, by the one rule its offer
    follows (`Computers.Switches.history_on?/2`, M97 D27): its recorder
    switched on (its own setting), its master switch on and its switches
    reviewed; otherwise nothing is sent and the sitting waits.
  - At most one sitting is in flight per computer: the sending cycle is single
    flight (its claim), and the waiting process is registered under one name,
    so `answer/3`, which `Desktop.Invoke.Admission` calls with every answer the
    home sends this computer, finds it.
  - It waits at most #{180} s past the request's deadline for the home's
    summary; past that it asks the home to cancel, from the same process,
    naming the request's capability and op, and the sitting is sent again on a
    later cycle, which the home answers from its note if it made one.

  Options (a test's seams): `:relay`, `:switches` (this computer's switches),
  `:recording?` (whether its recorder is switched on), `:waiter` (the
  registered name).
  """

  require Logger

  alias FermixChannels.Desktop.Relay
  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Submission
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.Switches

  @waiter __MODULE__.Waiter
  @deadline_ms 180_000
  @margin_ms 5_000

  @doc """
  Send `payload` (one sitting) to the home and wait for its answer:
  `{:ok, answer}` (`Submission.answer/0`), or why there is none.
  """
  @spec submit(map(), keyword()) :: {:ok, Submission.answer()} | {:error, term()}
  def submit(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    with {:ok, result} <- send_allowed("submit", payload, opts),
         do: Submission.from_wire(result)
  end

  @doc """
  Send `report` (`ComputerHistory.Report`) to the home and wait for it to be
  kept: `:ok`, or why not. Under the same switches as a sitting.
  """
  @spec report(map(), keyword()) :: :ok | {:error, term()}
  def report(report, opts \\ []) when is_map(report) and is_list(opts) do
    case send_allowed("report", report, opts) do
      {:ok, %{"kept" => true}} -> :ok
      {:ok, other} -> {:error, {:answer, other}}
      {:error, _reason} = error -> error
    end
  end

  defp send_allowed(op, payload, opts) do
    switches = Keyword.get_lazy(opts, :switches, &Switches.current/0)
    recording? = Keyword.get_lazy(opts, :recording?, &ComputerHistory.enabled?/0)

    if Switches.history_on?(switches, recording?),
      do: send_registered(op, payload, opts),
      else: {:error, :switched_off}
  end

  @doc """
  The home's answer to a request this computer sent, handed on to the process
  waiting on it; `:unknown` when none waits.
  """
  @spec answer(String.t(), map(), binary(), atom()) :: :ok | :unknown
  def answer(id, fields, payload, waiter \\ @waiter)
      when is_binary(id) and is_map(fields) and is_binary(payload) do
    case Process.whereis(waiter) do
      nil ->
        :unknown

      pid ->
        send(pid, {__MODULE__, id, fields, payload})
        :ok
    end
  end

  defp send_registered(op, payload, opts) do
    waiter = Keyword.get(opts, :waiter, @waiter)

    case register(waiter) do
      :ok ->
        try do
          send_and_wait(op, payload, Keyword.get(opts, :relay, Relay))
        after
          Process.unregister(waiter)
        end

      {:error, :busy} ->
        {:error, :busy}
    end
  end

  # Another sitting already waits: one at a time.
  defp register(waiter) do
    Process.register(self(), waiter)
    :ok
  rescue
    ArgumentError -> {:error, :busy}
  end

  defp send_and_wait(op, payload, relay) do
    with {:ok, epoch} <- epoch(relay),
         %{"id" => id} = open = request(epoch, op),
         :ok <- Relay.send_event(relay, open, Jason.encode!(payload)) do
      await(id, op, relay)
    end
  end

  @doc false
  # The `invoke_open` of one sitting (or report, `op`) under `epoch`, with an
  # id never used before, in the wire's alphabet (letters, digits and `._:-`,
  # `Mobile.PeerEvents`). Public so its test holds it against the codec.
  @spec request(pos_integer(), String.t()) :: map()
  def request(epoch, op \\ "submit")
      when is_integer(epoch) and epoch > 0 and op in ["submit", "report"],
      do: open("hist-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower), epoch, op)

  defp epoch(relay) do
    case Relay.status(relay) do
      %{connected: true, epoch: epoch} when is_integer(epoch) and epoch > 0 -> {:ok, epoch}
      _away -> {:error, :unreachable}
    end
  end

  defp open(id, epoch, op) do
    %{
      "t" => "invoke_open",
      "id" => id,
      "capability" => "history",
      "op" => op,
      "deadline_ms" => @deadline_ms,
      "epoch" => epoch,
      "origin" => "computer"
    }
  end

  defp await(id, op, relay) do
    receive do
      {__MODULE__, ^id, fields, payload} -> read(fields, payload)
    after
      @deadline_ms + @margin_ms -> give_up(id, op, relay)
    end
  end

  defp read(fields, payload) do
    case Outcome.from_wire(fields, payload) do
      {:ok, %Outcome{status: :ok, result: result}} -> {:ok, result}
      {:ok, %Outcome{status: status, refusal: refusal}} -> {:error, {status, refusal}}
      {:error, reason} -> {:error, {:answer, reason}}
    end
  end

  # The request's own cancel, after its open and from its process, naming its
  # capability and op so it rides the same lane.
  defp give_up(id, op, relay) do
    cancel = %{"t" => "invoke_cancel", "id" => id, "capability" => "history", "op" => op}

    case Relay.send_event(relay, cancel) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info("computer history: the cancel was not sent: #{inspect(reason)}")
    end

    {:error, :timeout}
  end
end
