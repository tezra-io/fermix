defmodule Mix.Tasks.Fermix.Resource.Show do
  @moduledoc """
  Print current or historical content for a Fermix resource.

      mix fermix.resource.show RESOURCE_TYPE [REVISION] [--scope SCOPE_ID] [--agent AGENT_ID]

  Omitting `REVISION` prints the current revision. Checkpoint resources require their
  conversation key with `--scope`.
  """

  use Mix.Task

  alias Mix.Tasks.Fermix.Resource.Common

  @shortdoc "Show resource revision content"

  @impl true
  def run(args) do
    {opts, argv} = Common.parse!(args)
    Common.ensure_repo!()

    opts
    |> load_revision(argv)
    |> then(fn revision -> Mix.shell().info(revision.content) end)
  end

  defp load_revision(opts, [resource_type]) do
    Common.current_revision!(Common.agent_id(opts), resource_type, Common.scope_id(opts))
  end

  defp load_revision(opts, [resource_type, revision]) do
    Common.revision!(
      Common.agent_id(opts),
      resource_type,
      Common.scope_id(opts),
      Common.positive_integer!(revision, "revision")
    )
  end

  defp load_revision(_opts, _argv) do
    Mix.raise("usage: mix fermix.resource.show RESOURCE_TYPE [REVISION] [--scope SCOPE_ID]")
  end
end
