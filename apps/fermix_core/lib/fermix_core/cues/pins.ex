defmodule FermixCore.Cues.Pins do
  @moduledoc """
  A mandate trusts its job, its skill and its validator as the owner left them
  (M60 §10.4), so the owner's approval records a digest of all of them and every
  mandate call compares it.

  The digest covers the mandate section (its switch aside: `enabled` stops calls
  without being a new grant), the job's task prompt, skill name, allowed tools
  and route pin, the validator file when one is set, and, when the job names a
  skill, every file under the skill's folder except the mandate's `unpinned`
  paths. It lives in `cue_mandate_approvals`, written only by the daemon: the
  setup page's Approve button and the management method call `approve/3`.

  A mandate starts unapproved. A digest that differs at a call disables the
  mandate until it is approved again, and the owner is told once (the write
  that disabled it sends the notice). `update_job` on a job a mandate names
  disables it the same way (`disable_for_job/3`).

  Seams (opts): `:repo`, `:now`, `:get_job` (as `Cues.Mandates`), `:skill_dir`
  (`fn skill_name -> {:ok, dir} | {:error, _}`), the `Cues.Mandates` seams for
  `approve/3`, and the `Cues.Notices` owner-inbox seams (`:adapter`,
  `:channels`, `:jobs_config`, `:configured_owners`).
  """

  require Logger

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Notices
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesMandateSql
  alias FermixCore.Plugins.CanonicalJson

  # Bounds on what one digest reads from a skill folder; a folder past them is
  # refused with a sentence that says how to fix it (`unpinned`).
  @max_skill_files 2_000
  @max_file_bytes 8 * 1024 * 1024
  @max_depth 16

  @typedoc "Where a mandate's approval stands, for the setup page."
  @type state :: :unapproved | :approved | :changed | :disabled

  @type status :: %{
          name: String.t(),
          state: state(),
          approved_at: DateTime.t() | nil,
          approved_from: String.t() | nil,
          disabled_at: DateTime.t() | nil,
          disabled_reason: String.t() | nil,
          detail: String.t() | nil
        }

  @doc """
  Records the owner's approval of mandate `name` as it is now and turns it back
  on. `approved_from` says where (for example `"setup page"`). Refused for an
  unknown or inactive mandate, with the reason.
  """
  @spec approve(String.t(), String.t() | nil, DateTime.t(), keyword()) ::
          {:ok, status()} | {:error, String.t()}
  def approve(name, approved_from, %DateTime{} = now, opts \\ [])
      when is_binary(name) and (is_binary(approved_from) or is_nil(approved_from)) and
             is_list(opts) do
    with {:ok, mandate} <- active_mandate(name, opts),
         {:ok, digest} <- digest(mandate, opts),
         {:ok, row} <- call({:approve, name, digest, approved_from, now}, opts) do
      Logger.info("Mandate #{name} approved from #{approved_from || "an unnamed surface"}")
      {:ok, status_of(name, row, :approved, nil)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "Mandate #{name} was not approved: #{inspect(reason)}"}
    end
  end

  @doc """
  Where mandate `name`'s approval stands: `:unapproved` (never approved),
  `:disabled` (with its reason), `:changed` (approved, but the task, skill,
  validator or mandate differ now; the next call disables it) or `:approved`.
  """
  @spec status(String.t(), keyword()) :: {:ok, status()} | {:error, term()}
  def status(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with {:ok, row} <- approval(name, opts) do
      {:ok, status_from_row(name, row, opts)}
    end
  end

  @doc "Mandate `name`'s approval row, or nil."
  @spec approval(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def approval(name, opts \\ []) when is_binary(name) and is_list(opts),
    do: call({:get_approval, name}, opts)

  @doc """
  Whether `mandate` is as the owner approved it (`row` is its approval).
  `{:error, :changed}` when a pinned part differs; `{:error, {:unreadable,
  sentence}}` when a pinned file cannot be read (a removed skill, a missing
  validator), which is a change too; `{:error, {:unverified, sentence}}` when
  the job's row could not be read (a busy or timed-out Repo), which says
  nothing about the pins, so the caller refuses only the one call.
  """
  @spec check(Mandates.t(), map(), keyword()) ::
          :ok | {:error, :changed | {:unreadable, String.t()} | {:unverified, String.t()}}
  def check(%Mandates{} = mandate, %{digest: approved}, opts \\ []) when is_list(opts) do
    case digest_of(mandate, opts) do
      {:ok, ^approved} -> :ok
      {:ok, _other} -> {:error, :changed}
      {:error, :job, sentence} -> {:error, {:unverified, sentence}}
      {:error, :pinned, sentence} -> {:error, {:unreadable, sentence}}
    end
  end

  @doc """
  Disables mandate `name` until it is approved again. The write that disabled
  it tells the owner (a mandate notice); a mandate already disabled, or never
  approved, sends nothing.
  """
  @spec disable(String.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, :disabled | :already_disabled | :unapproved} | {:error, term()}
  def disable(name, reason, %DateTime{} = now, opts \\ [])
      when is_binary(name) and is_binary(reason) and is_list(opts) do
    case call({:disable, name, reason, now}, opts) do
      {:ok, :disabled} ->
        Logger.warning("Mandate #{name} disabled: #{reason}")
        notify_disabled(name, now, opts)
        {:ok, :disabled}

      other ->
        other
    end
  end

  @doc """
  For `update_job`: disables every mandate whose section names `job_id` (design
  §10.4), before the job changes.
  """
  @spec disable_for_job(String.t(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def disable_for_job(job_id, %DateTime{} = now, opts \\ []) when is_binary(job_id) do
    job_id
    |> Mandates.names_for_job(opts)
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case disable(name, "the task was changed with update_job", now, opts) do
        {:ok, _state} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  The skill folder of `skill_name`, the one place a mandated cue run's file
  tools may read (design §10.4).
  """
  @spec skill_dir(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def skill_dir(skill_name, opts \\ []) when is_binary(skill_name) and is_list(opts) do
    case Keyword.get(opts, :skill_dir) do
      fun when is_function(fun, 1) -> fun.(skill_name)
      nil -> registry_skill_dir(skill_name)
    end
  end

  @doc "The digest of everything `mandate` pins, as it is now (lowercase hex)."
  @spec digest(Mandates.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def digest(%Mandates{} = mandate, opts \\ []) when is_list(opts) do
    case digest_of(mandate, opts) do
      {:ok, digest} -> {:ok, digest}
      {:error, _part, sentence} -> {:error, sentence}
    end
  end

  # The digest, or which part could not be read: the job's row (`:job`, a Repo
  # read) or a pinned file or document (`:pinned`).
  defp digest_of(mandate, opts) do
    with {:ok, job} <- fetch_job(mandate.job, opts),
         {:ok, validator} <- pinned(validator_digest(mandate.validator)),
         {:ok, skill} <- pinned(skill_digests(job, mandate.unpinned, opts)) do
      %{
        "mandate" => section_document(mandate),
        "job" => job_document(job),
        "validator" => validator,
        "skill" => skill
      }
      |> CanonicalJson.digest()
      |> canonical_result()
      |> pinned()
    end
  end

  defp pinned({:ok, value}), do: {:ok, value}
  defp pinned({:error, sentence}), do: {:error, :pinned, sentence}

  # --- digest parts ------------------------------------------------------------------

  defp section_document(mandate) do
    %{
      "name" => mandate.name,
      "job" => mandate.job,
      "mode" => Atom.to_string(mandate.mode),
      "approve_within_s" => mandate.approve_within_s,
      "tools" => mandate.tools,
      "read_tools" => mandate.read_tools,
      "max_cue_age_s" => mandate.max_cue_age_s,
      "validator" => mandate.validator,
      "interpreter" => mandate.interpreter,
      "validator_env" => mandate.validator_env,
      "idempotency_arg" => mandate.idempotency_arg,
      "unpinned" => mandate.unpinned,
      "pin_args" => mandate.pin_args
    }
  end

  defp job_document(job) do
    %{
      "task_prompt" => job.task_prompt,
      "skill_name" => job.skill_name,
      "allowed_tools" => job.allowed_tools || [],
      "provider" => job.provider,
      "model" => job.model
    }
  end

  defp validator_digest(nil), do: {:ok, nil}

  defp validator_digest(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, sha256(bytes)}
      {:error, reason} -> {:error, "The validator #{path} cannot be read: #{inspect(reason)}."}
    end
  end

  defp skill_digests(%{skill_name: nil}, _unpinned, _opts), do: {:ok, nil}

  defp skill_digests(%{skill_name: skill_name}, unpinned, opts) do
    case skill_dir(skill_name, opts) do
      {:ok, dir} -> folder_digests(dir, unpinned)
      {:error, reason} -> {:error, "The skill #{skill_name} cannot be read: #{inspect(reason)}."}
    end
  end

  defp folder_digests(dir, unpinned) do
    with {:ok, files} <- list_files(dir, "", 0, []) do
      files
      |> Enum.reject(&unpinned?(&1, unpinned))
      |> Enum.sort()
      |> digest_files(dir)
    end
  end

  # Depth-first, bounded in depth and in count. A symlink is pinned by its
  # target's text, never followed out of the folder.
  defp list_files(_dir, _rel, depth, _acc) when depth > @max_depth,
    do: {:error, "The skill folder is nested deeper than #{@max_depth} levels."}

  defp list_files(dir, rel, depth, acc) do
    case File.ls(Path.join(dir, rel)) do
      {:ok, names} -> Enum.reduce_while(names, {:ok, acc}, &visit(dir, rel, depth, &1, &2))
      {:error, reason} -> {:error, "The skill folder cannot be read: #{inspect(reason)}."}
    end
  end

  defp visit(dir, rel, depth, name, {:ok, acc}) do
    path = if rel == "", do: name, else: Path.join(rel, name)

    case File.lstat(Path.join(dir, path)) do
      {:ok, %File.Stat{type: :directory}} -> continue(list_files(dir, path, depth + 1, acc))
      {:ok, %File.Stat{}} -> continue(add_file(path, acc))
      {:error, reason} -> {:halt, {:error, "#{path} cannot be read: #{inspect(reason)}."}}
    end
  end

  defp add_file(_path, acc) when length(acc) >= @max_skill_files,
    do:
      {:error,
       "The skill folder holds more than #{@max_skill_files} files; list the folders the job " <>
         "writes in the mandate's unpinned."}

  defp add_file(path, acc), do: {:ok, [path | acc]}

  defp continue({:ok, acc}), do: {:cont, {:ok, acc}}
  defp continue({:error, _sentence} = error), do: {:halt, error}

  defp unpinned?(path, unpinned) do
    Enum.any?(unpinned, fn entry ->
      prefix = String.trim_trailing(entry, "/")
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  defp digest_files(paths, dir) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case file_digest(Path.join(dir, path), path) do
        {:ok, digest} -> {:cont, {:ok, [[path, digest] | acc]}}
        {:error, sentence} -> {:halt, {:error, sentence}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  defp file_digest(full, rel) do
    case File.lstat(full) do
      {:ok, %File.Stat{type: :symlink}} -> link_digest(full, rel)
      {:ok, %File.Stat{size: size}} when size > @max_file_bytes -> too_large(rel)
      {:ok, %File.Stat{}} -> read_digest(full, rel)
      {:error, reason} -> {:error, "#{rel} cannot be read: #{inspect(reason)}."}
    end
  end

  defp link_digest(full, rel) do
    case File.read_link(full) do
      {:ok, target} -> {:ok, "link:" <> target}
      {:error, reason} -> {:error, "#{rel} cannot be read: #{inspect(reason)}."}
    end
  end

  defp read_digest(full, rel) do
    case File.read(full) do
      {:ok, bytes} -> {:ok, sha256(bytes)}
      {:error, reason} -> {:error, "#{rel} cannot be read: #{inspect(reason)}."}
    end
  end

  defp too_large(rel) do
    {:error,
     "The skill file #{rel} is larger than 8 MiB; if the job writes it, list it in the " <>
       "mandate's unpinned."}
  end

  defp canonical_result({:ok, digest}), do: {:ok, digest}

  defp canonical_result({:error, reason}),
    do: {:error, "The mandate cannot be pinned: #{inspect(reason)}."}

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # --- status ------------------------------------------------------------------------

  defp status_from_row(name, nil, _opts), do: status_of(name, nil, :unapproved, nil)

  defp status_from_row(name, %{disabled_at: %DateTime{}} = row, _opts),
    do: status_of(name, row, :disabled, nil)

  defp status_from_row(name, row, opts) do
    case Mandates.get(name, opts) do
      {:ok, mandate} ->
        {state, detail} = compare(check(mandate, row, opts))
        status_of(name, row, state, detail)

      :error ->
        status_of(name, row, :changed, "No mandate section is named #{name} any more.")
    end
  end

  # A job row that could not be read says nothing about the pins: the state
  # stays as approved, with the sentence beside it.
  defp compare(:ok), do: {:approved, nil}
  defp compare({:error, :changed}), do: {:changed, nil}
  defp compare({:error, {:unreadable, sentence}}), do: {:changed, sentence}
  defp compare({:error, {:unverified, sentence}}), do: {:approved, sentence}

  defp status_of(name, row, state, detail) do
    %{
      name: name,
      state: state,
      approved_at: row && row.approved_at,
      approved_from: row && row.approved_from,
      disabled_at: row && row.disabled_at,
      disabled_reason: row && row.disabled_reason,
      detail: detail
    }
  end

  # --- helpers -----------------------------------------------------------------------

  defp active_mandate(name, opts) do
    case Mandates.get(name, opts) do
      {:ok, %Mandates{status: :active} = mandate} -> {:ok, mandate}
      {:ok, %Mandates{status: {:inactive, reason}}} -> {:error, reason}
      :error -> {:error, "No mandate is named #{name}."}
    end
  end

  defp fetch_job(job_id, opts) do
    result =
      case Keyword.get(opts, :get_job) do
        fun when is_function(fun, 1) -> fun.(job_id)
        nil -> JobsRegistry.get_job(job_id, repo: repo(opts))
      end

    case result do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, :job, "Job #{job_id} cannot be read: #{inspect(reason)}."}
    end
  end

  defp registry_skill_dir(skill_name) do
    case SkillRegistry.load(skill_name) do
      {:ok, %{source_path: path}} when is_binary(path) -> {:ok, Path.dirname(path)}
      {:ok, _definition} -> {:error, {:no_skill_folder, skill_name}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp notify_disabled(name, now, opts) do
    notice_opts = Keyword.put(opts, :now, now)

    case Notices.mandate(name, :unpinned, %{}, notice_opts) do
      {:error, reason} -> Logger.error("Mandate #{name} notice not sent: #{inspect(reason)}")
      _sent -> :ok
    end
  end

  defp call(request, opts), do: Repo.cues_call(CuesMandateSql, request, server: repo(opts))

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
