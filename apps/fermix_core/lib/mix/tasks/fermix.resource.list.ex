defmodule Mix.Tasks.Fermix.Resource.List do
  @moduledoc """
  List registered Fermix resources and their current revisions.

      mix fermix.resource.list [--agent AGENT_ID]
  """

  use Mix.Task

  alias FermixCore.Resource.Registry
  alias Mix.Tasks.Fermix.Resource.Common

  @shortdoc "List versioned Fermix resources"

  @impl true
  def run(args) do
    {opts, argv} = Common.parse!(args)
    ensure_no_args!(argv)
    Common.ensure_repo!()

    opts
    |> Common.agent_id()
    |> list_rows()
    |> print_rows()
  end

  defp ensure_no_args!([]), do: :ok
  defp ensure_no_args!(_argv), do: Mix.raise("usage: mix fermix.resource.list [--agent AGENT_ID]")

  defp list_rows(agent_id) do
    case Registry.list_resources(agent_id, Common.repo_opts()) do
      {:ok, resources} -> Enum.map(resources, &resource_row/1)
      {:error, reason} -> Mix.raise("failed to list resources: #{inspect(reason)}")
    end
  end

  defp resource_row(resource) do
    revision = current_revision(resource)

    [
      resource.resource_type,
      resource.scope_id,
      Integer.to_string(resource.current_revision),
      Common.format_timestamp(resource.updated_at),
      revision_value(revision, :mutation_source),
      revision_size(revision),
      revision_hash(revision)
    ]
  end

  defp current_revision(%{current_revision: 0}), do: nil

  defp current_revision(resource) do
    case Registry.get_revision(
           resource.agent_id,
           resource.resource_type,
           resource.scope_id,
           resource.current_revision,
           Common.repo_opts()
         ) do
      {:ok, revision} -> revision
      {:error, _reason} -> nil
    end
  end

  defp revision_value(nil, _key), do: "--"
  defp revision_value(revision, key), do: Map.fetch!(revision, key)
  defp revision_size(nil), do: "--"
  defp revision_size(revision), do: Common.format_size(revision.byte_size)
  defp revision_hash(nil), do: "--"
  defp revision_hash(revision), do: Common.short_hash(revision.content_hash)

  defp print_rows([]), do: Mix.shell().info("No registered resources.")

  defp print_rows(rows) do
    Mix.shell().info(
      Common.table(["Resource", "Scope", "Rev", "Last Updated", "Source", "Size", "Hash"], rows)
    )
  end
end
