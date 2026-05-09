defmodule FermixCore.Tools.ContentSearch do
  @moduledoc """
  Pure-Elixir grep across a directory tree.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Tools.Support

  @default_max_results 200
  @default_timeout_ms 30_000
  @binary_probe_bytes 4_096

  @impl true
  def name, do: "content_search"

  @impl true
  def description,
    do: "Search file contents across a workspace without shelling out to grep or rg."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["pattern"],
      properties: %{
        path: %{
          type: "string",
          description: "Root directory or file, defaulting to current directory."
        },
        pattern: %{type: "string", description: "Text or regex pattern to search for."},
        regex: %{type: "boolean", description: "Interpret pattern as a regular expression."},
        max_results: %{type: "integer", description: "Maximum matches to return, default 200."},
        timeout_ms: %{
          type: "integer",
          description: "Search timeout in milliseconds, default 30000."
        }
      }
    }
  end

  @impl true
  def when_to_use, do: "Search file contents across the workspace for text or regex matches."

  @impl true
  def examples do
    [
      %{args: %{"pattern" => "TODO", "path" => "apps"}, note: "find TODO comments"},
      %{args: %{"pattern" => "defmodule\\s+Name", "regex" => true}, note: "regex search"}
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_regex", description: "regex pattern did not compile"},
      %{tag: "timeout", description: "search exceeded timeout_ms"},
      %{tag: "not_found", description: "no matches; returns an empty match list"}
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
         :ok <- Support.validate_path(root),
         {:ok, matcher} <- matcher(pattern, Support.optional_bool(args, "regex", false)) do
      search(root, matcher, search_opts(args))
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp search_opts(args) do
    %{
      max_results: Support.optional_integer(args, "max_results", @default_max_results, 1, 1_000),
      deadline: System.monotonic_time(:millisecond) + timeout(args)
    }
  end

  defp timeout(args),
    do: Support.optional_integer(args, "timeout_ms", @default_timeout_ms, 1, 120_000)

  defp matcher(pattern, false), do: {:ok, {:text, pattern}}

  defp matcher(pattern, true) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, {:regex, regex}}
      {:error, {message, _at}} -> {:error, "invalid_regex: #{message}"}
    end
  end

  defp search(root, matcher, opts) do
    root
    |> candidate_files()
    |> collect_matches(matcher, opts, [])
    |> case do
      {:ok, matches, truncated?} ->
        Support.success_json(%{matches: matches, truncated: truncated?})

      {:error, reason} ->
        Support.error(reason)
    end
  end

  defp candidate_files(path) do
    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*"), match_dot: true)
      true -> []
    end
  end

  defp collect_matches(files, matcher, opts, acc) do
    Enum.reduce_while(files, {:ok, acc, false}, fn path, {:ok, matches, _truncated?} ->
      cond do
        timed_out?(opts.deadline) ->
          {:halt, {:error, "timeout"}}

        length(matches) >= opts.max_results ->
          {:halt, {:ok, Enum.reverse(matches), true}}

        File.regular?(path) and not binary_file?(path) ->
          next = search_file(path, matcher, opts, matches)
          {:cont, next}

        true ->
          {:cont, {:ok, matches, false}}
      end
    end)
    |> normalize_collected()
  end

  defp normalize_collected({:ok, matches, truncated?}),
    do: {:ok, Enum.reverse(matches), truncated?}

  defp normalize_collected({:error, reason}), do: {:error, reason}

  defp search_file(path, matcher, opts, matches) do
    path
    |> File.stream!([], :line)
    |> Stream.with_index(1)
    |> Enum.reduce_while({:ok, matches, false}, fn {line, number}, {:ok, acc, _truncated?} ->
      cond do
        timed_out?(opts.deadline) ->
          {:halt, {:error, "timeout"}}

        length(acc) >= opts.max_results ->
          {:halt, {:ok, acc, true}}

        line_match?(line, matcher) ->
          hit = %{path: Path.expand(path), line: number, text: String.trim_trailing(line)}
          {:cont, {:ok, [hit | acc], false}}

        true ->
          {:cont, {:ok, acc, false}}
      end
    end)
  end

  defp line_match?(line, {:text, pattern}), do: String.contains?(line, pattern)
  defp line_match?(line, {:regex, regex}), do: Regex.match?(regex, line)

  defp binary_file?(path) do
    case File.open(path, [:read], fn io -> IO.binread(io, @binary_probe_bytes) end) do
      {:ok, bytes} when is_binary(bytes) -> String.contains?(bytes, <<0>>)
      _other -> true
    end
  end

  defp timed_out?(deadline), do: System.monotonic_time(:millisecond) > deadline
end
