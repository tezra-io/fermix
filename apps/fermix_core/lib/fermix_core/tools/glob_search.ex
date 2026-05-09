defmodule FermixCore.Tools.GlobSearch do
  @moduledoc """
  Find files by glob pattern.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Tools.Support

  @default_max_results 200

  @impl true
  def name, do: "glob_search"

  @impl true
  def description, do: "Find files matching a glob pattern under a root path."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["pattern"],
      properties: %{
        path: %{type: "string", description: "Root directory, defaulting to current directory."},
        pattern: %{type: "string", description: "Glob pattern such as **/*.ex."},
        max_results: %{type: "integer", description: "Maximum paths to return, default 200."}
      }
    }
  end

  @impl true
  def when_to_use, do: "Find files by name or extension with a glob pattern."

  @impl true
  def examples,
    do: [%{args: %{"pattern" => "**/*.ex", "path" => "apps"}, note: "find Elixir files"}]

  @impl true
  def failure_modes do
    [
      %{tag: "missing_pattern", description: "pattern is absent or blank"},
      %{tag: "invalid_path", description: "path is invalid"},
      %{tag: "not_found", description: "no matching files; returns an empty list"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :file

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args) end)
  end

  defp do_execute(args) do
    with {:ok, pattern} <- Support.required_string(args, "pattern"),
         root = Map.get(args, "path", File.cwd!()),
         :ok <- Support.validate_path(root) do
      max_results = Support.optional_integer(args, "max_results", @default_max_results, 1, 1_000)

      root
      |> Path.join(pattern)
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.sort()
      |> Enum.take(max_results)
      |> Support.success_json()
    else
      {:error, reason} -> Support.error(reason)
    end
  end
end
