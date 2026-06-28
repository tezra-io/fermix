defmodule FermixCore.Resource.Registry do
  @moduledoc """
  SQLite-backed registry for versioned prompt and memory resources.
  """

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Resource.Revision

  require Logger

  @resource_types ~w(identity_md fermix_md soul_md realtime_md user_md memory_md checkpoint)
  @file_resource_types ~w(identity_md fermix_md soul_md realtime_md user_md memory_md)
  @mutation_sources ~w(seed imported manual_edit extraction_rebuild scheduler_rebuild compaction rollback soul_curation)
  @max_commit_attempts 4

  @type resource_row :: Repo.resource_row()

  @spec list_resources(String.t(), keyword()) :: {:ok, [resource_row()]} | {:error, term()}
  def list_resources(agent_id, opts \\ []) when is_binary(agent_id) and is_list(opts) do
    Repo.list_resources(%{agent_id: agent_id}, repo_opts(opts))
  end

  @spec ensure_registered(String.t(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, resource_row()} | {:error, term()}
  def ensure_registered(agent_id, resource_type, scope_id, opts \\ [])
      when is_binary(agent_id) and is_binary(scope_id) and is_list(opts) do
    with {:ok, type} <- normalize_resource_type(resource_type) do
      selector = resource_selector(agent_id, type, scope_id)

      case Repo.get_resource(selector, repo_opts(opts)) do
        {:ok, resource} ->
          {:ok, resource}

        {:error, :not_found} ->
          selector
          |> Map.merge(%{
            current_revision: 0,
            resource_path: Keyword.get(opts, :resource_path)
          })
          |> Repo.upsert_resource(repo_opts(opts))

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec get_resource(String.t(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, resource_row()} | {:error, term()}
  def get_resource(agent_id, resource_type, scope_id, opts \\ [])
      when is_binary(agent_id) and is_binary(scope_id) and is_list(opts) do
    with {:ok, type} <- normalize_resource_type(resource_type) do
      Repo.get_resource(resource_selector(agent_id, type, scope_id), repo_opts(opts))
    end
  end

  @spec commit(String.t(), String.t() | atom(), String.t(), String.t(), keyword()) ::
          {:ok, Revision.t() | :unchanged} | {:error, term()}
  def commit(agent_id, resource_type, scope_id, content, opts)
      when is_binary(agent_id) and is_binary(scope_id) and is_binary(content) and is_list(opts) do
    with {:ok, type} <- normalize_resource_type(resource_type),
         {:ok, source} <- required_mutation_source(opts) do
      attrs = %{
        agent_id: agent_id,
        resource_type: type,
        scope_id: scope_id,
        content_hash: content_hash(content),
        content: content,
        byte_size: byte_size(content),
        mutation_source: source,
        provenance: Keyword.get(opts, :provenance),
        resource_path: Keyword.get(opts, :resource_path)
      }

      commit_with_retry(attrs, opts, 1)
    end
  end

  @doc """
  Commit a new revision and rewrite the file-backed resource on disk, in that
  order: write the file first (the harder operation to recover), then commit
  the registry row. If the commit fails after the write, restore the prior
  on-disk bytes so disk never leads the registry — one compensating recovery
  step (Rule #12), never a silent fallback. Mirrors `rollback/5`'s commit +
  `rewrite_file/2` bundling for the forward direction, so callers (soul
  curation, future managed-resource writers) never open-code a second writer.

  Requires `:mutation_source` in `opts` exactly like `commit/5`. Rejects a
  resource type that has no on-disk file (`checkpoint`) or is unknown.
  """
  @spec commit_and_write(String.t(), String.t() | atom(), String.t(), String.t(), keyword()) ::
          {:ok, Revision.t() | :unchanged} | {:error, term()}
  def commit_and_write(agent_id, resource_type, scope_id, content, opts)
      when is_binary(agent_id) and is_binary(scope_id) and is_binary(content) and is_list(opts) do
    with {:ok, type} <- normalize_resource_type(resource_type),
         :ok <- ensure_file_backed(type),
         {:ok, path} <- resource_path(agent_id, type, scope_id, opts),
         {:ok, prior} <- read_existing(path),
         :ok <- rewrite_file(path, content) do
      commit_after_write(agent_id, type, scope_id, content, path, prior, opts)
    end
  end

  @doc """
  SHA256 hex digest of `content`, the same hash the registry stores per
  revision. Public so callers comparing on-disk bytes against the recorded
  revision (e.g. soul-curation stale-base checks) hash identically.
  """
  @spec content_hash(String.t()) :: String.t()
  def content_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @spec current_revision(String.t(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def current_revision(agent_id, resource_type, scope_id, opts \\ [])
      when is_binary(agent_id) and is_binary(scope_id) and is_list(opts) do
    with {:ok, type} <- normalize_resource_type(resource_type),
         {:ok, resource} <-
           Repo.get_resource(resource_selector(agent_id, type, scope_id), repo_opts(opts)) do
      {:ok, resource.current_revision}
    end
  end

  @spec current_hash(String.t(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def current_hash(agent_id, resource_type, scope_id, opts \\ [])
      when is_binary(agent_id) and is_binary(scope_id) and is_list(opts) do
    with {:ok, %Revision{} = revision} <-
           current_revision_struct(agent_id, resource_type, scope_id, opts) do
      {:ok, revision.content_hash}
    end
  end

  @spec get_revision(String.t(), String.t() | atom(), String.t(), pos_integer(), keyword()) ::
          {:ok, Revision.t()} | {:error, term()}
  def get_revision(agent_id, resource_type, scope_id, revision_number, opts \\ [])
      when is_binary(agent_id) and is_binary(scope_id) and is_integer(revision_number) and
             revision_number > 0 and is_list(opts) do
    with {:ok, type} <- normalize_resource_type(resource_type),
         {:ok, row} <-
           Repo.get_revision(
             Map.put(resource_selector(agent_id, type, scope_id), :revision, revision_number),
             repo_opts(opts)
           ) do
      {:ok, Revision.from_repo_row(row)}
    end
  end

  @spec list_revisions(String.t(), String.t() | atom(), String.t(), keyword()) ::
          {:ok, [Revision.t()]} | {:error, term()}
  def list_revisions(agent_id, resource_type, scope_id, opts \\ [])
      when is_binary(agent_id) and is_binary(scope_id) and is_list(opts) do
    with {:ok, type} <- normalize_resource_type(resource_type),
         {:ok, rows} <-
           Repo.list_revisions(
             resource_selector(agent_id, type, scope_id),
             repo_opts(opts) ++ page_opts(opts)
           ) do
      {:ok, Enum.map(rows, &Revision.from_repo_row/1)}
    end
  end

  @spec rollback(String.t(), String.t() | atom(), String.t(), pos_integer(), keyword()) ::
          {:ok, Revision.t() | :already_at_target} | {:error, term()}
  def rollback(agent_id, resource_type, scope_id, target_revision, opts \\ [])
      when is_binary(agent_id) and is_binary(scope_id) and is_integer(target_revision) and
             target_revision > 0 and is_list(opts) do
    with {:ok, type} <- normalize_resource_type(resource_type),
         :ok <- ensure_rollback_supported(type),
         {:ok, target} <- get_revision(agent_id, type, scope_id, target_revision, opts),
         {:ok, current} <- current_revision_struct(agent_id, type, scope_id, opts),
         false <- current.content_hash == target.content_hash,
         {:ok, path} <- resource_path(agent_id, type, scope_id, opts),
         {:ok, %Revision{} = revision} <-
           commit(agent_id, type, scope_id, target.content,
             mutation_source: :rollback,
             provenance: rollback_provenance(target.revision, current.revision),
             resource_path: path,
             repo: Keyword.get(opts, :repo, Keyword.get(opts, :server, Repo))
           ),
         :ok <- rewrite_file(path, target.content) do
      {:ok, revision}
    else
      true -> {:ok, :already_at_target}
      {:ok, :unchanged} -> {:ok, :already_at_target}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_revision_struct(agent_id, resource_type, scope_id, opts) do
    with {:ok, type} <- normalize_resource_type(resource_type),
         {:ok, resource} <-
           Repo.get_resource(resource_selector(agent_id, type, scope_id), repo_opts(opts)),
         true <- resource.current_revision > 0,
         {:ok, row} <-
           Repo.get_revision(
             Map.put(
               resource_selector(agent_id, type, scope_id),
               :revision,
               resource.current_revision
             ),
             repo_opts(opts)
           ) do
      {:ok, Revision.from_repo_row(row)}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_with_retry(attrs, opts, attempt) do
    case Repo.commit_resource_revision(attrs, repo_opts(opts)) do
      {:ok, :unchanged} -> {:ok, :unchanged}
      {:ok, row} -> {:ok, Revision.from_repo_row(row)}
      {:error, :busy} when attempt < @max_commit_attempts -> retry_commit(attrs, opts, attempt)
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_commit(attrs, opts, attempt) do
    Process.sleep(attempt * 10)
    commit_with_retry(attrs, opts, attempt + 1)
  end

  defp normalize_resource_type(type) when is_atom(type),
    do: normalize_resource_type(Atom.to_string(type))

  defp normalize_resource_type(type) when is_binary(type) do
    if type in @resource_types do
      {:ok, type}
    else
      {:error, {:unsupported_resource_type, type}}
    end
  end

  defp required_mutation_source(opts) do
    case Keyword.fetch(opts, :mutation_source) do
      {:ok, source} -> normalize_mutation_source(source)
      :error -> {:error, :missing_mutation_source}
    end
  end

  defp normalize_mutation_source(source) when is_atom(source) do
    source
    |> Atom.to_string()
    |> normalize_mutation_source()
  end

  defp normalize_mutation_source(source) when is_binary(source) do
    if source in @mutation_sources do
      {:ok, source}
    else
      {:error, {:unsupported_mutation_source, source}}
    end
  end

  defp ensure_rollback_supported("checkpoint"), do: {:error, :checkpoint_rollback_not_implemented}
  defp ensure_rollback_supported(type) when type in @file_resource_types, do: :ok

  defp resource_selector(agent_id, resource_type, scope_id) do
    %{agent_id: agent_id, resource_type: resource_type, scope_id: scope_id}
  end

  defp resource_path(agent_id, type, scope_id, opts) do
    case Repo.get_resource(resource_selector(agent_id, type, scope_id), repo_opts(opts)) do
      {:ok, %{resource_path: path}} when is_binary(path) and path != "" -> {:ok, path}
      {:ok, _resource} -> default_resource_path(agent_id, type, opts)
      {:error, :not_found} -> default_resource_path(agent_id, type, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_resource_path(agent_id, "identity_md", opts) do
    {:ok, Path.join([bootstrap_dir(opts), agent_id, "IDENTITY.md"])}
  end

  defp default_resource_path(agent_id, "fermix_md", opts) do
    {:ok, Path.join([bootstrap_dir(opts), agent_id, "FERMIX.md"])}
  end

  defp default_resource_path(agent_id, "soul_md", opts) do
    {:ok, Path.join([bootstrap_dir(opts), agent_id, "SOUL.md"])}
  end

  defp default_resource_path(agent_id, "realtime_md", opts) do
    {:ok, Path.join([bootstrap_dir(opts), agent_id, "REALTIME.md"])}
  end

  defp default_resource_path(agent_id, "user_md", opts) do
    {:ok, Path.join([Config.prompt_base_dir(opts), agent_id, "USER.md"])}
  end

  defp default_resource_path(agent_id, "memory_md", opts) do
    {:ok, Path.join([Config.prompt_base_dir(opts), agent_id, "MEMORY.md"])}
  end

  defp bootstrap_dir(opts), do: BootstrapPaths.bootstrap_dir(opts)

  defp rollback_provenance(target_revision, from_revision) do
    %{
      trigger: "rollback",
      target_revision: target_revision,
      from_revision: from_revision,
      description:
        "Operator rolled back from revision #{from_revision} to revision #{target_revision}"
    }
  end

  defp rewrite_file(path, content) do
    temp_path = temp_path(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp_path, content),
         :ok <- File.rename(temp_path, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temp_path)
        error
    end
  end

  defp temp_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{path}.tmp-#{suffix}"
  end

  defp commit_after_write(agent_id, type, scope_id, content, path, prior, opts) do
    case commit(agent_id, type, scope_id, content, Keyword.put(opts, :resource_path, path)) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> restore_after_failure(path, prior, reason)
    end
  end

  defp restore_after_failure(path, prior, reason) do
    case restore_prior(path, prior) do
      :ok ->
        {:error, {:commit_failed, reason}}

      {:error, restore_reason} ->
        Logger.error(
          "resource commit failed and compensating restore also failed for #{path}: " <>
            "commit=#{inspect(reason)} restore=#{inspect(restore_reason)}"
        )

        {:error, {:commit_failed_restore_failed, reason, restore_reason}}
    end
  end

  defp read_existing(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_prior(path, nil) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_prior(path, prior) when is_binary(prior), do: rewrite_file(path, prior)

  defp ensure_file_backed(type) when type in @file_resource_types, do: :ok
  defp ensure_file_backed(type), do: {:error, {:not_file_backed, type}}

  defp repo_opts(opts), do: [server: Keyword.get(opts, :repo, Keyword.get(opts, :server, Repo))]

  defp page_opts(opts) do
    opts
    |> Keyword.take([:limit, :offset])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
