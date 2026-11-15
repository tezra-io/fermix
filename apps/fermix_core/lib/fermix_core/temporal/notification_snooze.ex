defmodule FermixCore.Temporal.NotificationSnooze do
  @moduledoc """
  The home service a computer invokes when the owner presses Snooze on a
  reminder's notification there (M99 §10.1): `reminders.snooze`, run by the
  home's side of the link (`Desktop.InvokeFamily`), since the reminder is the
  server's and a computer holds no memory.

  It takes `{"reminder_id": …, "minutes": …}` (an id of 1 to #{64}
  characters, 1 to #{1_440} minutes) and nothing else, and is
  `Temporal.Registry.snooze_from_notification/3`, the one snooze a press
  makes, so it answers what that answers: `{"status": "created"}`, or
  `"existing"` for a press made again; a refusal fails in the registry's own
  sentence (`Registry.describe_error/1`). It is an effect: the link never
  sends one twice, and a press made twice snoozes once.

  The context's `reminders` are the registry's options (a test's seams: its
  Repo, scheduler, owner and clock; none in production).
  """

  @behaviour FermixCore.Computers.Capability

  require Logger

  alias FermixCore.Temporal.Registry

  @max_id_chars 64
  @max_minutes 1_440

  @impl true
  def id, do: :reminders

  @impl true
  def offer, do: nil

  @impl true
  def ops, do: ["snooze"]

  @impl true
  def effect?("snooze"), do: true

  @impl true
  def long_lived?("snooze"), do: false

  @impl true
  def validate("snooze", %{"reminder_id" => id, "minutes" => minutes} = args)
      when map_size(args) == 2 and is_binary(id) and is_integer(minutes) do
    if String.valid?(id) and String.length(id) in 1..@max_id_chars and
         minutes in 1..@max_minutes,
       do: :ok,
       else: {:error, shape()}
  end

  def validate("snooze", _args), do: {:error, shape()}

  @impl true
  def bounds("snooze"), do: %{result_bytes: 1_024, part_bytes: 0}

  @impl true
  def admit("snooze", _args, _context), do: :ok

  @impl true
  def run("snooze", %{"reminder_id" => id, "minutes" => minutes}, nil, context),
    do: snoozed(id, minutes, Map.get(context, :reminders, []))

  def run("snooze", _args, _part, _context), do: {:failed, "A snooze carries no file."}

  @impl true
  def target("snooze", %{"reminder_id" => id}) when is_binary(id), do: "reminder " <> id
  def target("snooze", _args), do: "reminder"

  # The registry's Repo and scheduler calls can exit (a Repo call that timed
  # out); the press then fails alone, said in the log and in its answer.
  defp snoozed(id, minutes, opts) do
    case Registry.snooze_from_notification(id, minutes, opts) do
      {:ok, %{status: status}} -> {:ok, %{"status" => Atom.to_string(status)}, nil}
      {:error, reason} -> {:failed, Registry.describe_error(reason)}
    end
  catch
    :exit, reason ->
      Logger.error(
        "reminder #{id} was not snoozed for a computer: the registry did not answer " <>
          "(#{inspect(reason, limit: 5, printable_limit: 200)})"
      )

      {:failed, "This server could not snooze the reminder now."}
  end

  defp shape,
    do:
      "A snooze takes reminder_id, 1 to #{@max_id_chars} characters, and minutes, 1 to " <>
        "#{@max_minutes}."
end
