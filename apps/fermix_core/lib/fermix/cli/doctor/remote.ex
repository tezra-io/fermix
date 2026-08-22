defmodule Fermix.CLI.Doctor.Remote do
  @moduledoc """
  Runs `fermix doctor` against the daemon's management socket (M34 §4).

  On an app-managed engine the CLI process and the daemon are different
  processes with different world-views: the daemon holds the bootstrap home and
  the application's durable identity, and a check evaluated in the CLI would
  inspect a world the work does not run in. So the checks run where the daemon
  runs, and this module only drives `doctor.start` / `doctor.get` and renders
  what comes back.

  The scopes are disjoint catalogs with their own whole-run budgets, so `--full`
  is two sessions — local, then network — not one wider session.
  """

  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Management.Doctor.Descriptor

  @poll_interval_ms 250
  # Slack beyond the session's own budget. The daemon resolves its own deadline;
  # this only bounds how long the CLI waits for it to say so.
  @poll_slack_ms 5_000
  # Wide enough for the longest word in `Descriptor.statuses/0`.
  @status_width 14
  @id_width 26

  @type scope :: :local | :network
  @type client :: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})

  @doc """
  Runs one scope to a terminal status and prints its report.

  Returns `{:ok, exit_status}` where the status is non-zero when a check failed
  or the session did not complete, and `{:error, reason}` when the daemon could
  not be asked at all.
  """
  @spec run(scope(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(scope, opts) when scope in [:local, :network] and is_list(opts) do
    client = Keyword.get(opts, :client, &Client.request_v1/3)
    sleep = Keyword.get(opts, :poll_sleep, &Process.sleep/1)

    with {:ok, view} <- client.("doctor.start", %{"scope" => Atom.to_string(scope)}, []),
         {:ok, final} <- await(view, client, sleep) do
      print_report(final)
      {:ok, exit_for(final)}
    end
  end

  defp await(%{"status" => status} = view, _client, _sleep) when status != "running",
    do: {:ok, view}

  defp await(view, client, sleep) do
    session_id = Map.get(view, "session_id")
    poll(session_id, client, sleep, max_polls(view))
  end

  defp poll(_session_id, _client, _sleep, remaining) when remaining <= 0,
    do: {:error, :doctor_session_unfinished}

  defp poll(session_id, client, sleep, remaining) do
    sleep.(@poll_interval_ms)

    case client.("doctor.get", %{"session_id" => session_id}, []) do
      {:ok, %{"status" => "running"}} -> poll(session_id, client, sleep, remaining - 1)
      {:ok, view} -> {:ok, view}
      {:error, reason} -> {:error, reason}
    end
  end

  defp max_polls(view) do
    budget = Map.get(view, "budget_ms")
    budget = if is_integer(budget) and budget > 0, do: budget, else: 0
    div(budget + @poll_slack_ms, @poll_interval_ms)
  end

  @doc "Prints one typed session report."
  @spec print_report(map()) :: :ok
  def print_report(view) when is_map(view) do
    IO.puts("fermix doctor (#{Map.get(view, "scope", "unknown")})")
    IO.puts(String.duplicate("-", 60))

    view
    |> Map.get("checks", [])
    |> Enum.each(&print_check/1)

    IO.puts("")
    IO.puts(session_line(view))
    IO.puts(summary_line(view))
  end

  defp print_check(check) when is_map(check) do
    status = String.pad_trailing(to_string(Map.get(check, "status", "unknown")), @status_width)
    id = String.pad_trailing(to_string(Map.get(check, "id", "unknown")), @id_width)
    IO.puts("[#{status}] #{id}  #{Map.get(check, "summary", "")}")
  end

  defp session_line(view) do
    "session #{Map.get(view, "session_id", "unknown")}, " <>
      "#{Map.get(view, "status", "unknown")} in #{Map.get(view, "duration_ms", 0)}ms " <>
      "(#{Map.get(view, "completed_count", 0)} of #{Map.get(view, "total", 0)} checks)"
  end

  # The vocabulary comes from the descriptor authority, not a second copy of it,
  # so a status added there appears here instead of being silently unprinted.
  defp summary_line(view) do
    summary = Map.get(view, "summary", %{})

    Enum.map_join(Descriptor.statuses(), ", ", fn status ->
      "#{Map.get(summary, status, 0)} #{status}"
    end)
  end

  # A session that did not complete verified nothing about the checks it never
  # ran, so it is a failed run even with no failed check in it.
  @spec exit_for(map()) :: non_neg_integer()
  defp exit_for(view) do
    failed = view |> Map.get("summary", %{}) |> Map.get("failed", 0)

    if Map.get(view, "status") == "completed" and failed == 0, do: 0, else: 1
  end
end
