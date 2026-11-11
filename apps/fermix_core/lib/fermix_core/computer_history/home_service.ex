defmodule FermixCore.ComputerHistory.HomeService do
  @moduledoc """
  The services a computer invokes on its home for its history (M97 §6.1,
  §8.1, §8.5), run by the home's side of the link (`Desktop.InvokeFamily`),
  which names the computer:

  - `history.submit`: one finished sitting (`ComputerHistory.Submission`): its
    rendered text, or the note a computer that summarizes on its own device
    made, with its key, time range, counts and artifacts, at most 1 MiB, with
    no part. It answers the home's word for the sitting (`summarized`,
    `abstained`, `no_signal` or `refused` with its reason and, for a purge or
    pause, the intervals to apply), and the computer moves its cursor on it.
  - `history.report`: the computer's report of its recorder
    (`ComputerHistory.Report`: a state word and counts), kept as its latest
    with when it came, for `/history status`.
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixCore.ComputerHistory.Report
  alias FermixCore.ComputerHistory.Submission
  alias FermixCore.Memory.Repo

  @impl true
  def id, do: :history

  @impl true
  def offer, do: nil

  @impl true
  def ops, do: ["submit", "report"]

  # A sitting writes a note; one sent again makes none (the home keys them). A
  # report replaces the last one, so one sent twice changes nothing.
  @impl true
  def effect?("submit"), do: true
  def effect?("report"), do: false

  @impl true
  def long_lived?(op) when op in ["submit", "report"], do: false

  @impl true
  def validate("submit", args) when is_map(args), do: Submission.validate(args)
  def validate("report", args) when is_map(args), do: Report.validate(args)

  @impl true
  def bounds("submit"), do: %{result_bytes: 64 * 1_024, part_bytes: 0}
  def bounds("report"), do: %{result_bytes: 1_024, part_bytes: 0}

  @impl true
  def admit(op, _args, _context) when op in ["submit", "report"], do: :ok

  @impl true
  def run(op, args, nil, %{computer: computer} = context)
      when op in ["submit", "report"] and is_binary(computer) and computer != "",
      do: serve(op, args, computer, Map.get(context, :history, []))

  def run(_op, _args, _part, _context), do: {:failed, "This carries no file."}

  defp serve("submit", args, computer, history) do
    answer = Submission.accept(computer, args, history)
    {:ok, Submission.to_wire(answer), nil}
  end

  defp serve("report", args, computer, history) do
    at = System.system_time(:millisecond)

    case Repo.computer_history_home(:record_report, [computer, Jason.encode!(args), at],
           server: Keyword.get(history, :repo, Repo)
         ) do
      :ok -> {:ok, %{"kept" => true}, nil}
      {:error, reason} -> {:failed, "This server could not keep the report: #{inspect(reason)}"}
    end
  end

  @impl true
  def target("submit", %{"sitting" => key}) when is_binary(key), do: "sitting " <> key
  def target("submit", _args), do: "sitting"
  def target("report", _args), do: "recorder report"
end
