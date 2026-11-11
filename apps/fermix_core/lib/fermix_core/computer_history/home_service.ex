defmodule FermixCore.ComputerHistory.HomeService do
  @moduledoc """
  `history.submit` (M97 §6.1, §8.1): the one service a computer invokes on its
  home. Its arguments are one finished sitting (`ComputerHistory.Submission`):
  its rendered text, or the note a computer that summarizes on its own device
  made, with its key, time range, counts and artifacts, at most 1 MiB, with no
  part. It answers the home's word for the sitting (`summarized`, `abstained`,
  `no_signal` or `refused` with its reason and, for a purge or pause, the
  intervals to apply), and the computer moves its cursor on it. Run by the
  home's side of the link (`Desktop.InvokeFamily`), which names the computer.
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixCore.ComputerHistory.Submission

  @impl true
  def id, do: :history

  @impl true
  def offer, do: nil

  @impl true
  def ops, do: ["submit"]

  # It writes a note; a sitting sent again makes none (the home keys them).
  @impl true
  def effect?("submit"), do: true

  @impl true
  def long_lived?("submit"), do: false

  @impl true
  def validate("submit", args) when is_map(args), do: Submission.validate(args)

  @impl true
  def bounds("submit"), do: %{result_bytes: 64 * 1_024, part_bytes: 0}

  @impl true
  def admit("submit", _args, _context), do: :ok

  @impl true
  def run("submit", args, nil, %{computer: computer} = context)
      when is_binary(computer) and computer != "" do
    answer = Submission.accept(computer, args, Map.get(context, :history, []))
    {:ok, Submission.to_wire(answer), nil}
  end

  def run("submit", _args, _part, _context), do: {:failed, "A sitting carries no file."}

  @impl true
  def target("submit", %{"sitting" => key}) when is_binary(key), do: "sitting " <> key
  def target("submit", _args), do: "sitting"
end
