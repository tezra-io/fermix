defmodule FermixCore.Watch do
  @moduledoc """
  Live watch mode: a supervised, attended-only loop that observes the user's live
  screen (or a browser session it drives) and reports — or acts read-only — as
  things change, delivering updates back to the conversation until stopped.

  Opt-in, **off by default** (like computer-use): the `Watch.Supervisor` and the
  `watch`/`stop_watch` tools are wired only when enabled, so a disabled install
  carries no residue and the model never sees a tool it can't run.
  """

  @doc """
  Whether watch mode is enabled — config `[fermix_core] watch: [enabled: true]`,
  default `false`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    :fermix_core
    |> Application.get_env(:watch, [])
    |> Keyword.get(:enabled, false)
    |> Kernel.==(true)
  end
end
