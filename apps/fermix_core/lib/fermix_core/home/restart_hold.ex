defmodule FermixCore.Home.RestartHold do
  @moduledoc """
  What holds an Always On server's restart after an update (M97 §3.4): a
  move under way, as before, and now work in progress on a computer (a
  command, a screen session or a message send it runs for the home), for at
  most #{10} minutes from the oldest one's start. `home.status` answers it as
  `restart_hold`, and the server's update (`fermix-update`) restarts the
  engine only once it is null or its `wait_s` is 0: work still running then
  ends as a receipt or unknown (§6.3), and never holds the server back for
  longer.

  Pure: `view/3` takes the move's phase (one the move code treats as
  pending, or nil), the work in progress (each a map with its
  `started_at`), and the time now.
  """

  @max_wait_s 600
  # The phases the move code treats as pending: this server sending its home,
  # or a candidate enrolling or receiving one (`packaging/cloud/first-boot.sh`
  # reads the same list).
  @move_phases ~w(requested streaming committing aborting enrolling receiving staged activating)

  @type hold :: %{
          reason: :move | :computer_work,
          count: non_neg_integer(),
          wait_s: 0..600,
          sentence: String.t()
        }

  @doc "The longest computer work holds a restart, in seconds."
  @spec max_wait_s() :: pos_integer()
  def max_wait_s, do: @max_wait_s

  @doc """
  The hold on a restart, or nil: a pending move holds it for as long as it
  runs (`wait_s` #{600}, read again at each update); work in progress holds
  it until #{600} seconds after the oldest started, then `wait_s` is 0.
  """
  @spec view(String.t() | nil, [map()], DateTime.t()) :: hold() | nil
  def view(phase, running, %DateTime{} = now)
      when (is_nil(phase) or is_binary(phase)) and is_list(running) do
    cond do
      phase in @move_phases -> move_hold()
      running == [] -> nil
      true -> work_hold(running, now)
    end
  end

  @doc "The hold as `home.status` answers it, or nil."
  @spec to_map(hold() | nil) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%{reason: reason, count: count, wait_s: wait_s, sentence: sentence}),
    do: %{
      "reason" => Atom.to_string(reason),
      "count" => count,
      "wait_s" => wait_s,
      "sentence" => sentence
    }

  @doc "Every sentence a hold says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences, do: [move_sentence(), work_sentence(1), work_sentence(3)]

  defp move_hold,
    do: %{reason: :move, count: 0, wait_s: @max_wait_s, sentence: move_sentence()}

  defp work_hold(running, now) do
    oldest = running |> Enum.map(&started_at!/1) |> Enum.min(DateTime)
    waited = max(DateTime.diff(now, oldest, :second), 0)
    count = length(running)

    %{
      reason: :computer_work,
      count: count,
      wait_s: max(@max_wait_s - waited, 0),
      sentence: work_sentence(count)
    }
  end

  defp started_at!(%{started_at: %DateTime{} = at}), do: at

  defp started_at!(other),
    do: raise(ArgumentError, "work in progress needs its started_at: #{inspect(other)}")

  defp move_sentence,
    do: "A move is under way, so Fermix on your server restarts once it is done."

  defp work_sentence(1),
    do:
      "Fermix on your server restarts once the work it runs on a computer ends, or in " <>
        "ten minutes at most."

  defp work_sentence(_count),
    do:
      "Fermix on your server restarts once the work it runs on your computers ends, or in " <>
        "ten minutes at most."
end
