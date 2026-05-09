defmodule FermixCore.Tools.MemorySourcesList do
  @moduledoc """
  List memory sources visible to the main agent.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Jobs.Registry
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "memory_sources_list"

  @impl true
  def description, do: "List memory sources with names and provenance metadata."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        status: %{type: "string", description: "Optional source status filter."},
        source_type: %{type: "string", description: "Optional source type filter."}
      }
    }
  end

  @impl true
  def when_to_use do
    "List durable memory sources and provenance before reasoning about where memories came from."
  end

  @impl true
  def examples, do: [%{args: %{"status" => "active"}, note: "list active memory sources"}]

  @impl true
  def failure_modes do
    [
      %{tag: "registry_failed", description: "memory-source registry query failed"},
      %{tag: "invalid_filter", description: "status or source_type filter is invalid"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :memory

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    opts = [repo: Support.repo(context)]

    opts =
      ["status", "source_type"]
      |> Enum.reduce(opts, fn key, acc ->
        case Support.optional_string(args, key) do
          nil -> acc
          value -> Keyword.put(acc, String.to_existing_atom(key), value)
        end
      end)

    case Registry.list_memory_sources(opts) do
      {:ok, sources} ->
        Support.success_json(%{sources: Enum.map(sources, &Support.source_payload/1)})

      {:error, reason} ->
        Support.error(reason)
    end
  end
end
