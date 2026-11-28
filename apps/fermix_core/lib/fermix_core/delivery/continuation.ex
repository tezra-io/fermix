defmodule FermixCore.Delivery.Continuation do
  @moduledoc """
  The continuation dispatcher every run kind that re-enters its conversation
  hands its notice to: a coding run (`Harness.Continuation`) and a phone call
  (`PhoneCalls.Continuation`). `dispatcher/1` is the one lookup: the injected
  `opts[:dispatcher]` (the test seam), else the module configured under
  `config :fermix_core, :harness_continuation_dispatcher`, the key the coding
  run named first, validated against the `Harness.ContinuationDispatcher`
  behaviour it implements.
  """

  require Logger

  @doc """
  The configured dispatcher module: `opts[:dispatcher]` or the configured one.
  `:none` when no dispatcher is configured (continuation is off) or the
  configured module cannot serve the behaviour; the latter logs loud.
  """
  @spec dispatcher(keyword()) :: {:ok, module()} | :none
  def dispatcher(opts) when is_list(opts) do
    case Keyword.get(opts, :dispatcher) || configured_dispatcher() do
      nil -> :none
      module -> validate_dispatcher(module)
    end
  end

  defp configured_dispatcher do
    Application.get_env(:fermix_core, :harness_continuation_dispatcher)
  end

  defp validate_dispatcher(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :dispatch, 1) do
      {:ok, module}
    else
      Logger.error(
        "harness continuation dispatcher #{inspect(module)} does not export dispatch/1; " <>
          "run outcomes are delivered as text instead of continuing the conversation"
      )

      :none
    end
  end
end
