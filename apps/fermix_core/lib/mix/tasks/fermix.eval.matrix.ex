defmodule Mix.Tasks.Fermix.Eval.Matrix do
  @shortdoc "Dump the provider × model matrix the capability eval sweeps over"

  @moduledoc """
  Emits the full provider × model matrix — every config the capability eval can
  rank — as JSON on stdout, derived live from the in-code registries
  (`FermixCore.Providers.Descriptor` + `FermixCore.Providers.ModelCatalog`).

  The eval sweep enumerates configs from THIS, never from a hand-copied list, so
  the matrix can never drift from the catalog the daemon actually serves
  (docs/design/EVAL_CAPABILITY_SCORING.md §2). Provider order matches
  `Descriptor.ids/0` (the load-bearing fallback order).

      mix fermix.eval.matrix

  Pure and read-only: it touches no GenServer, no socket, no network — it just
  projects two compile-time registries, so it is safe to run against any daemon
  state (or none).
  """

  use Mix.Task

  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.ModelCatalog.Entry

  @impl Mix.Task
  def run(_argv) do
    IO.puts(Jason.encode!(%{providers: matrix()}, pretty: true))
  end

  @doc """
  The provider × model matrix as plain maps (one entry per provider, in
  `Descriptor` order). Public and pure so the sweep — and tests — can consume it
  without going through the task's stdout.
  """
  @spec matrix() :: [map()]
  def matrix do
    Enum.map(Descriptor.all(), &provider_entry/1)
  end

  defp provider_entry(%Descriptor{} = descriptor) do
    models = ModelCatalog.models_for(descriptor.id)

    %{
      id: descriptor.id,
      label: descriptor.label,
      auth_modes: descriptor.auth_modes,
      effort: descriptor.effort?,
      default_base_url: descriptor.default_base_url,
      default_model: ModelCatalog.default_model_for(descriptor.id),
      models: Enum.map(models, &model_entry/1)
    }
  end

  defp model_entry(%Entry{} = entry) do
    %{
      id: entry.id,
      label: entry.label,
      context_window: entry.context_window,
      reasoning_effort: entry.reasoning_effort?,
      vision: entry.vision?
    }
  end
end
