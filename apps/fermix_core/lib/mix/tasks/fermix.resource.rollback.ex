defmodule Mix.Tasks.Fermix.Resource.Rollback do
  @moduledoc """
  Roll back a file-backed Fermix resource to a prior revision.

      mix fermix.resource.rollback RESOURCE_TYPE REVISION [--scope SCOPE_ID] [--agent AGENT_ID] [--yes]

  This creates a new append-only revision with the target revision's content.
  Rollback is not supported for checkpoint resources.

  Caveat: rolling back `USER.md` or `MEMORY.md` only restores the prompt file.
  It does not mutate rows in the memory table, so future rebuilds may overwrite
  the file if promoted memories are unchanged.
  """

  use Mix.Task

  alias FermixCore.Resource.Diff
  alias FermixCore.Resource.Registry
  alias Mix.Tasks.Fermix.Resource.Common

  @shortdoc "Roll back a file-backed resource revision"

  @impl true
  def run(args) do
    {opts, argv} = Common.parse!(args)
    [resource_type, revision] = require_args!(argv)
    Common.ensure_repo!()

    revision_number = Common.positive_integer!(revision, "revision")
    maybe_reject_checkpoint!(resource_type)
    preview_and_rollback(opts, resource_type, revision_number)
  end

  defp require_args!([resource_type, revision]), do: [resource_type, revision]

  defp require_args!(_argv) do
    Mix.raise("usage: mix fermix.resource.rollback RESOURCE_TYPE REVISION [--scope SCOPE_ID]")
  end

  defp maybe_reject_checkpoint!("checkpoint") do
    Mix.shell().info(Common.checkpoint_rollback_message())
    Mix.raise("checkpoint rollback is not implemented")
  end

  defp maybe_reject_checkpoint!(_resource_type), do: :ok

  defp preview_and_rollback(opts, resource_type, target_revision_number) do
    agent_id = Common.agent_id(opts)
    scope_id = Common.scope_id(opts)
    current = Common.current_revision!(agent_id, resource_type, scope_id)
    target = Common.revision!(agent_id, resource_type, scope_id, target_revision_number)

    print_preview(resource_type, current, target)

    if confirmed?(opts) do
      rollback!(agent_id, resource_type, scope_id, target_revision_number)
    else
      Mix.shell().info("Rollback cancelled.")
    end
  end

  defp print_preview(resource_type, current, target) do
    Mix.shell().info(
      "Rolling back #{resource_type} from revision #{current.revision} to revision #{target.revision}."
    )

    Mix.shell().info(
      "This will create revision #{current.revision + 1} with the content of revision #{target.revision}."
    )

    case Common.memory_rebuild_caveat(resource_type) do
      nil -> :ok
      caveat -> Mix.shell().info(caveat)
    end

    Mix.shell().info("Diff (current -> target):")
    print_preview_diff(current, target)
  end

  defp print_preview_diff(current, target) do
    diff_opts = [
      label_old: Common.label(current, "(current)"),
      label_new: Common.label(target, "(target)")
    ]

    case Diff.unified(current.content, target.content, diff_opts) do
      {:ok, diff} ->
        Common.print_diff(diff, "Current and target revisions have identical content.")

      {:error, reason} ->
        Mix.raise("failed to build rollback diff: #{inspect(reason)}")
    end
  end

  defp confirmed?(opts) do
    Keyword.get(opts, :yes, false) or Mix.shell().yes?("Proceed?")
  end

  defp rollback!(agent_id, resource_type, scope_id, target_revision_number) do
    case Registry.rollback(
           agent_id,
           resource_type,
           scope_id,
           target_revision_number,
           Common.repo_opts()
         ) do
      {:ok, :already_at_target} ->
        Mix.shell().info("Already at target content; no new revision created.")

      {:ok, revision} ->
        Mix.shell().info("Rolled back. New revision: #{revision.revision}")
        print_rewrite_result(agent_id, resource_type, scope_id)

      {:error, reason} ->
        Mix.raise("rollback failed: #{inspect(reason)}")
    end
  end

  defp print_rewrite_result(agent_id, resource_type, scope_id) do
    case Registry.get_resource(agent_id, resource_type, scope_id, Common.repo_opts()) do
      {:ok, %{resource_path: path}} when is_binary(path) and path != "" ->
        Mix.shell().info("File rewritten: #{path}")

      {:ok, _resource} ->
        Mix.shell().info("File rewrite path: unavailable")

      {:error, reason} ->
        Mix.raise("failed to load rewrite result: #{inspect(reason)}")
    end
  end
end
