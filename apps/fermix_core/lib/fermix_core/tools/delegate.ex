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
  def description, do: "Send one prompt to another configured model and return its text reply."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["model", "prompt"],
      properties: %{
        model: %{type: "string", description: "Target model id."},
        provider: %{
          type: "string",
          description: "Optional provider key: openai, openai_codex, anthropic."
        },
        prompt: %{type: "string", description: "Single-turn delegation prompt."}
      }
    }
  end

  @impl true
  def when_to_use, do: "Ask another configured model for one bounded answer without tool calls."

  @impl true
  def examples do
    [
      %{
        args: %{"model" => "gpt-5.4-mini", "prompt" => "Review this idea."},
        note: "delegate one turn"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "model or prompt is absent"},
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
    with {:ok, model} <- Support.required_string(args, "model"),
         {:ok, prompt} <- Support.required_string(args, "prompt"),
         {:ok, adapter, opts} <- resolve_delegate_route(args, context, model),
         {:ok, turn} <- adapter.chat([%{role: "user", content: prompt}], [], opts) do
      {:ok, Tool.success(turn.content)}
    else
      {:error, reason} when is_binary(reason) -> Support.error(reason)
      {:error, reason} -> Support.error("delegate failed: #{inspect(reason)}")
    end
  end

  defp resolve_delegate_route(_args, context, model) do
    case Map.fetch(context, :delegate_adapter) do
      {:ok, adapter} -> {:ok, adapter, [model: model]}
      :error -> resolve_configured_route(model)
    end
  end

  defp resolve_configured_route(model) do
    {route_key, opts} = RouteResolver.resolve!(model: model)
    {:ok, Adapter.for_route(route_key), opts}
  rescue
    error in ArgumentError -> {:error, "route_failed: #{Exception.message(error)}"}
  end
end
