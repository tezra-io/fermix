defmodule Fermix.CLI.CapabilitiesCommand do
  @moduledoc """
  `fermix capabilities` — print registered runtime capabilities.
  """

  alias Fermix.CLI.Daemon.Client

  @not_running_exit 3

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case OptionParser.parse(argv, strict: [json: :boolean, kind: :string]) do
      {opts, [], []} -> request_capabilities(opts)
      {_opts, _args, invalid} -> invalid_options(invalid)
    end
  end

  defp request_capabilities(opts) do
    params = %{"kind" => Keyword.get(opts, :kind, "all")}

    case Client.request("capabilities", params: params) do
      {:ok, %{"status" => "ok", "capabilities" => capabilities}} ->
        print_capabilities(capabilities, Keyword.get(opts, :json, false))

      {:ok, %{"status" => "error", "reason" => reason}} ->
        error(reason)

      {:ok, other} ->
        unexpected(other)

      {:error, :not_running} ->
        not_running()

      {:error, reason} ->
        error(reason)
    end
  end

  defp print_capabilities(capabilities, true) do
    IO.puts(Jason.encode!(capabilities))
    0
  end

  defp print_capabilities(capabilities, false) do
    counts = Map.get(capabilities, "counts", %{})
    rows = Map.get(capabilities, "capabilities", [])

    IO.puts(
      "capabilities: #{Map.get(counts, "total", 0)} " <>
        "(builtin #{Map.get(counts, "builtin", 0)}, skill #{Map.get(counts, "skill", 0)}, " <>
        "mcp #{Map.get(counts, "mcp", 0)})"
    )

    Enum.each(rows, &print_row/1)
    0
  end

  defp print_row(row) do
    IO.puts("- #{Map.get(row, "name")} [#{Map.get(row, "kind")}] #{Map.get(row, "description")}")
  end

  defp invalid_options(invalid) do
    IO.puts(:stderr, "fermix capabilities: invalid options #{inspect(invalid)}")
    2
  end

  defp unexpected(reply) do
    IO.puts(:stderr, "fermix capabilities: unexpected reply: #{inspect(reply)}")
    1
  end

  defp not_running do
    IO.puts(:stderr, "fermix: not running")
    @not_running_exit
  end

  defp error(reason) do
    IO.puts(:stderr, "fermix capabilities: #{inspect(reason)}")
    1
  end
end
