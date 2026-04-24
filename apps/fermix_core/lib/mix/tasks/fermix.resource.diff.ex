defmodule Mix.Tasks.Fermix.Resource.Diff do
  @moduledoc """
  Show a unified diff between two revisions of a Fermix resource.

      mix fermix.resource.diff RESOURCE_TYPE REV_A REV_B [--scope SCOPE_ID] [--agent AGENT_ID]

  Checkpoint resources are conversation-scoped; pass their conversation key with `--scope`.
  """

  use Mix.Task

  alias FermixCore.Resource.Diff
  alias Mix.Tasks.Fermix.Resource.Common

  @shortdoc "Diff two resource revisions"

  @impl true
  def run(args) do
    {opts, argv} = Common.parse!(args)
    [resource_type, rev_a, rev_b] = require_args!(argv)
    Common.ensure_repo!()

    run_diff(opts, resource_type, rev_a, rev_b)
  end

  defp require_args!([resource_type, rev_a, rev_b]), do: [resource_type, rev_a, rev_b]

  defp require_args!(_argv) do
    Mix.raise("usage: mix fermix.resource.diff RESOURCE_TYPE REV_A REV_B [--scope SCOPE_ID]")
  end

  defp run_diff(opts, resource_type, rev_a, rev_b) do
    revision_a = Common.positive_integer!(rev_a, "rev_a")
    revision_b = Common.positive_integer!(rev_b, "rev_b")

    diff_opts =
      Common.repo_opts() ++
        [
          context_lines: Keyword.get(opts, :context, 3)
        ]

    case Diff.between_revisions(
           Common.agent_id(opts),
           resource_type,
           Common.scope_id(opts),
           revision_a,
           revision_b,
           diff_opts
         ) do
      {:ok, diff} -> Common.print_diff(diff, identical_message(revision_a, revision_b))
      {:error, reason} -> Mix.raise("failed to diff revisions: #{inspect(reason)}")
    end
  end

  defp identical_message(rev_a, rev_b) do
    "Revisions #{rev_a} and #{rev_b} have identical content."
  end
end
