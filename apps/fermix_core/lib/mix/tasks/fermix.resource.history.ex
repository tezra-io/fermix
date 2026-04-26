defmodule Mix.Tasks.Fermix.Resource.History do
  @moduledoc """
  Show revision history for one Fermix resource.

      mix fermix.resource.history RESOURCE_TYPE [--scope SCOPE_ID] [--agent AGENT_ID] [--limit N]

  Checkpoint resources are conversation-scoped; pass their conversation key with `--scope`.
  """

  use Mix.Task

  alias FermixCore.Resource.Registry
  alias Mix.Tasks.Fermix.Resource.Common

  @shortdoc "Show resource revision history"

  @impl true
  def run(args) do
    {opts, argv} = Common.parse!(args)
    [resource_type] = require_args!(argv)
    Common.ensure_repo!()

    opts
    |> history_rows(resource_type)
    |> print_rows(resource_type, Common.scope_id(opts))
  end

  defp require_args!([resource_type]), do: [resource_type]

  defp require_args!(_argv) do
    Mix.raise("usage: mix fermix.resource.history RESOURCE_TYPE [--scope SCOPE_ID] [--limit N]")
  end

  defp history_rows(opts, resource_type) do
    query_opts = Common.repo_opts() ++ limit_opts(opts)

    case Registry.list_revisions(
           Common.agent_id(opts),
           resource_type,
           Common.scope_id(opts),
           query_opts
         ) do
      {:ok, revisions} -> Enum.map(revisions, &revision_row/1)
      {:error, reason} -> Mix.raise("failed to load history: #{inspect(reason)}")
    end
  end

  defp limit_opts(opts) do
    case Keyword.get(opts, :limit) do
      nil -> []
      limit when is_integer(limit) and limit > 0 -> [limit: limit]
      _limit -> Mix.raise("--limit must be a positive integer")
    end
  end

  defp revision_row(revision) do
    [
      Integer.to_string(revision.revision),
      Common.format_timestamp(revision.created_at),
      revision.mutation_source,
      Common.format_size(revision.byte_size),
      Common.short_hash(revision.content_hash),
      parent_revision(revision.parent_revision)
    ]
  end

  defp parent_revision(nil), do: "--"
  defp parent_revision(revision), do: Integer.to_string(revision)

  defp print_rows([], resource_type, scope_id) do
    Mix.shell().info("No revisions for #{resource_type} scope #{scope_id}.")
  end

  defp print_rows(rows, _resource_type, _scope_id) do
    Mix.shell().info(Common.table(["Rev", "Date", "Source", "Size", "Hash", "Parent"], rows))
  end
end
