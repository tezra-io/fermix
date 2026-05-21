defmodule FermixCore.Tools.Delegate do
  @moduledoc """
  Single-turn delegation to another configured model.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.RouteResolver
  alias FermixCore.Tools.Support

  @impl true
  def name, do: "delegate"

  @impl true
  def description,
    do:
      "Send one prompt to a sub-agent and return its text reply. " <>
        "The model is resolved from routing.delegate_model or the active provider's default."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["prompt"],
      properties: %{
        prompt: %{type: "string", description: "Single-turn delegation prompt."}
      }
    }
  end

  @impl true
  def when_to_use, do: "Ask a sub-agent for one bounded answer without tool calls."

  @impl true
  def examples do
    [
      %{
        args: %{"prompt" => "Summarize this article in three bullets."},
        note: "delegate one turn"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "prompt is absent"},
      %{tag: "route_failed", description: "provider/model routing could not be resolved"},
      %{tag: "provider_failed", description: "target model call failed"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :delegation

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, prompt} <- Support.required_string(args, "prompt"),
         {:ok, adapter, opts} <- resolve_delegate_route(context),
         {:ok, turn} <- adapter.chat([%{role: "user", content: prompt}], [], opts) do
      {:ok, Tool.success(turn.content)}
    else
      {:error, reason} when is_binary(reason) -> Support.error(reason)
      {:error, reason} -> Support.error("delegate failed: #{inspect(reason)}")
    end
  end

  defp resolve_delegate_route(context) do
    resolver_opts = configured_model_opts()

    case Map.fetch(context, :delegate_adapter) do
      {:ok, adapter} -> {:ok, adapter, resolver_opts}
      :error -> resolve_configured_route(resolver_opts)
    end
  end

  defp resolve_configured_route(resolver_opts) do
    {route_key, opts} = RouteResolver.resolve!(resolver_opts)
    {:ok, Adapter.for_route(route_key), opts}
  rescue
    error in ArgumentError -> {:error, "route_failed: #{Exception.message(error)}"}
  end

  defp configured_model_opts do
    case configured_delegate_model() do
      nil -> []
      model -> [model: model]
    end
  end

  defp configured_delegate_model do
    :fermix_core
    |> Application.get_env(:routing, [])
    |> Keyword.get(:delegate_model)
  end
end
