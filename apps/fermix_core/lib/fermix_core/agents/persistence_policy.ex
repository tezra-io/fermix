defmodule FermixCore.Agents.PersistencePolicy do
  @moduledoc """
  Executable M2 persistence contract for skill journals and agent snapshots.

  Skill journals are mandatory terminal-state records. Persistent agent snapshots
  are explicitly disabled in M2.
  """

  alias FermixCore.Agents.LifecycleTelemetry

  @skill_terminal_statuses [:completed, :failed, :timed_out, :crashed]

  @type skill_terminal_status :: :completed | :failed | :timed_out | :crashed

  @type skill_journal_entry :: %{
          required(:skill) => String.t(),
          required(:task) => String.t(),
          required(:summary) => String.t(),
          required(:status) => skill_terminal_status(),
          optional(:context) => String.t(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:failure) => String.t(),
          optional(:files_changed) => [String.t()],
          optional(:invoked_by) => String.t(),
          optional(:result) => String.t(),
          optional(:session_id) => String.t(),
          optional(:timestamp) => DateTime.t()
        }

  @type skill_journal_error ::
          {:invalid_journal_entry, term()}
          | {:journal_write_failed, skill_terminal_status(), term()}

  @spec skill_journal_policy() :: %{
          mandatory: true,
          write_on_statuses: [skill_terminal_status()],
          write_before_result?: true,
          retention: :retain_until_manual_cleanup,
          mutation: :write_once,
          failure_mode: :fail_closed
        }
  def skill_journal_policy do
    %{
      mandatory: true,
      write_on_statuses: @skill_terminal_statuses,
      write_before_result?: true,
      retention: :retain_until_manual_cleanup,
      mutation: :write_once,
      failure_mode: :fail_closed
    }
  end

  @spec agent_snapshot_policy() :: %{
          enabled?: false,
          mandatory: false,
          write_on_statuses: [],
          restore_on_restart?: false,
          retention: :none,
          failure_mode: :reject_attempt
        }
  def agent_snapshot_policy do
    %{
      enabled?: false,
      mandatory: false,
      write_on_statuses: [],
      restore_on_restart?: false,
      retention: :none,
      failure_mode: :reject_attempt
    }
  end

  @spec write_skill_journal(skill_journal_entry(), keyword()) ::
          {:ok, String.t()} | {:error, skill_journal_error()}
  def write_skill_journal(entry, opts \\ []) when is_map(entry) do
    with {:ok, normalized_entry} <- normalize_entry(entry),
         path <- journal_path(normalized_entry, opts),
         markdown <- render_skill_journal(normalized_entry),
         :ok <- ensure_parent_dir(path, normalized_entry.status),
         :ok <- write_markdown(path, markdown, normalized_entry.status) do
      emit_journal_write(normalized_entry, path, markdown)
      {:ok, path}
    end
  end

  @spec persist_agent_snapshot(map(), keyword()) :: {:error, :snapshot_persistence_disabled}
  def persist_agent_snapshot(_snapshot, _opts \\ []) do
    {:error, :snapshot_persistence_disabled}
  end

  @spec restore_agent_snapshot(String.t(), keyword()) :: {:error, :snapshot_persistence_disabled}
  def restore_agent_snapshot(_agent_name, _opts \\ []) do
    {:error, :snapshot_persistence_disabled}
  end

  defp normalize_entry(entry) do
    with :ok <- validate_required_string(entry, :skill),
         :ok <- validate_required_string(entry, :task),
         :ok <- validate_required_string(entry, :summary),
         :ok <- validate_status(entry),
         :ok <- validate_optional_string(entry, :context),
         :ok <- validate_optional_string(entry, :failure),
         :ok <- validate_optional_string(entry, :invoked_by),
         :ok <- validate_optional_string(entry, :result),
         :ok <- validate_optional_string(entry, :session_id),
         :ok <- validate_optional_duration(entry),
         :ok <- validate_optional_files_changed(entry),
         :ok <- validate_optional_timestamp(entry) do
      {:ok,
       entry
       |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.truncate(:second))
       |> Map.put_new(:invoked_by, "main-agent")
       |> Map.put_new(:session_id, "unknown")}
    end
  end

  defp validate_required_string(entry, key) do
    case Map.fetch(entry, key) do
      {:ok, value} when is_binary(value) and value != "" -> :ok
      _ -> {:error, {:invalid_journal_entry, {:missing_or_invalid, key}}}
    end
  end

  defp validate_optional_string(entry, key) do
    case Map.get(entry, key) do
      nil -> :ok
      value when is_binary(value) -> :ok
      _ -> {:error, {:invalid_journal_entry, {:invalid, key}}}
    end
  end

  defp validate_status(entry) do
    case Map.get(entry, :status) do
      status when status in @skill_terminal_statuses -> :ok
      status -> {:error, {:invalid_journal_entry, {:invalid_status, status}}}
    end
  end

  defp validate_optional_duration(entry) do
    case Map.get(entry, :duration_ms) do
      nil -> :ok
      value when is_integer(value) and value >= 0 -> :ok
      _ -> {:error, {:invalid_journal_entry, {:invalid, :duration_ms}}}
    end
  end

  defp validate_optional_files_changed(entry) do
    case Map.get(entry, :files_changed) do
      nil ->
        :ok

      files when is_list(files) ->
        if Enum.all?(files, &is_binary/1) do
          :ok
        else
          {:error, {:invalid_journal_entry, {:invalid, :files_changed}}}
        end

      _ ->
        {:error, {:invalid_journal_entry, {:invalid, :files_changed}}}
    end
  end

  defp validate_optional_timestamp(entry) do
    case Map.get(entry, :timestamp) do
      nil -> :ok
      %DateTime{} -> :ok
      _ -> {:error, {:invalid_journal_entry, {:invalid, :timestamp}}}
    end
  end

  defp journal_path(entry, opts) do
    base_dir = Keyword.get(opts, :base_dir, default_journals_dir())
    file_name = "#{timestamp_prefix(entry.timestamp)}_#{task_slug(entry.task)}.md"

    Path.join([base_dir, entry.skill, file_name])
  end

  defp render_skill_journal(entry) do
    [
      "# ",
      entry.skill,
      " — ",
      entry.task,
      "\n\n",
      "**Date:** ",
      DateTime.to_iso8601(entry.timestamp),
      "\n",
      "**Session:** ",
      entry.session_id,
      "\n",
      "**Invoked by:** ",
      entry.invoked_by,
      "\n",
      "**Duration:** ",
      format_duration(entry[:duration_ms]),
      "\n",
      "**Status:** ",
      Atom.to_string(entry.status),
      "\n\n",
      "## Task\n",
      entry.task,
      "\n\n",
      optional_section("## Context\n", entry[:context]),
      "## Execution Summary\n",
      entry.summary,
      "\n\n",
      optional_files_changed(entry[:files_changed]),
      optional_section("## Failure\n", entry[:failure]),
      optional_section("## Result\n", entry[:result])
    ]
    |> IO.iodata_to_binary()
  end

  defp optional_section(_heading, nil), do: []
  defp optional_section(_heading, ""), do: []
  defp optional_section(heading, value), do: [heading, value, "\n\n"]

  defp optional_files_changed(nil), do: []
  defp optional_files_changed([]), do: []

  defp optional_files_changed(files) do
    [
      "## Files Changed\n",
      Enum.map(files, fn file -> ["- ", file, "\n"] end),
      "\n"
    ]
  end

  defp ensure_parent_dir(path, status) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:journal_write_failed, status, reason}}
    end
  end

  defp write_markdown(path, markdown, status) do
    case File.write(path, markdown, [:exclusive]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:journal_write_failed, status, reason}}
    end
  end

  defp emit_journal_write(entry, path, markdown) do
    LifecycleTelemetry.skill_journal_write(
      entry.skill,
      entry.session_id,
      path,
      byte_size(markdown)
    )
  end

  defp timestamp_prefix(timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d_%H-%M-%S")
  end

  defp task_slug(task) do
    task
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
    |> case do
      "" -> "task"
      slug -> slug
    end
  end

  defp format_duration(nil), do: "n/a"

  defp format_duration(duration_ms) do
    seconds =
      duration_ms
      |> Kernel./(1_000)
      |> Float.ceil()
      |> trunc()

    "#{seconds}s"
  end

  defp default_journals_dir do
    Path.join(System.user_home!(), ".fermix/journals")
  end
end
