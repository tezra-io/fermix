defmodule FermixCore.Resource.Diff do
  @moduledoc """
  Unified diff helpers for versioned resource revisions.
  """

  alias FermixCore.Resource.Registry
  alias FermixCore.Resource.Revision

  @type diff_result :: {:ok, String.t() | :identical} | {:error, term()}

  @spec unified(String.t(), String.t(), keyword()) :: diff_result()
  def unified(old_content, new_content, opts \\ [])
      when is_binary(old_content) and is_binary(new_content) and is_list(opts) do
    with {:ok, context_lines} <- context_lines(opts),
         {:ok, old_path, new_path} <- write_temp_files(old_content, new_content) do
      run_diff(old_path, new_path, context_lines, opts)
    end
  end

  @spec between_revisions(
          String.t(),
          String.t() | atom(),
          String.t(),
          pos_integer(),
          pos_integer(),
          keyword()
        ) :: diff_result()
  def between_revisions(agent_id, resource_type, scope_id, rev_a, rev_b, opts \\ [])
      when is_binary(agent_id) and is_binary(scope_id) and is_integer(rev_a) and
             is_integer(rev_b) and rev_a > 0 and rev_b > 0 and is_list(opts) do
    with {:ok, old_revision} <-
           Registry.get_revision(agent_id, resource_type, scope_id, rev_a, opts),
         {:ok, new_revision} <-
           Registry.get_revision(agent_id, resource_type, scope_id, rev_b, opts) do
      unified(
        old_revision.content,
        new_revision.content,
        Keyword.merge(opts, revision_labels(old_revision, new_revision))
      )
    end
  end

  defp context_lines(opts) do
    case Keyword.get(opts, :context_lines, 3) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_context_lines, value}}
    end
  end

  defp write_temp_files(old_content, new_content) do
    dir = System.tmp_dir!()
    suffix = System.unique_integer([:positive, :monotonic])
    old_path = Path.join(dir, "fermix-resource-old-#{suffix}.tmp")
    new_path = Path.join(dir, "fermix-resource-new-#{suffix}.tmp")

    with :ok <- File.write(old_path, old_content),
         :ok <- File.write(new_path, new_content) do
      {:ok, old_path, new_path}
    else
      {:error, reason} ->
        File.rm(old_path)
        File.rm(new_path)
        {:error, reason}
    end
  end

  defp run_diff(old_path, new_path, context_lines, opts) do
    args = diff_args(old_path, new_path, context_lines, opts)

    try do
      case System.cmd("diff", args, stderr_to_stdout: true) do
        {"", 0} -> {:ok, :identical}
        {diff, 1} -> {:ok, diff}
        {output, status} -> {:error, {:diff_failed, status, output}}
      end
    after
      File.rm(old_path)
      File.rm(new_path)
    end
  end

  defp diff_args(old_path, new_path, 3, opts) do
    ["-u"] ++ label_args(opts) ++ [old_path, new_path]
  end

  defp diff_args(old_path, new_path, context_lines, opts) do
    ["-U", Integer.to_string(context_lines)] ++ label_args(opts) ++ [old_path, new_path]
  end

  defp label_args(opts) do
    [
      "-L",
      Keyword.get(opts, :label_old, "old"),
      "-L",
      Keyword.get(opts, :label_new, "new")
    ]
  end

  defp revision_labels(%Revision{} = old_revision, %Revision{} = new_revision) do
    [
      label_old: revision_label(old_revision),
      label_new: revision_label(new_revision)
    ]
  end

  defp revision_label(%Revision{} = revision) do
    "#{revision.resource_type} @ revision #{revision.revision} (#{format_timestamp(revision.created_at)})"
  end

  defp format_timestamp(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end
end
