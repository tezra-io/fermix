defmodule Fermix.CLI.AgentsCommand do
  @moduledoc """
  `fermix agents` — print main-agent and skill-worker status.
  """

  alias Fermix.CLI.Daemon.Client

  @not_running_exit 3

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case OptionParser.parse(argv, strict: [json: :boolean]) do
      {opts, [], []} -> request_agents(Keyword.get(opts, :json, false))
      {_opts, _args, invalid} -> invalid_options(invalid)
    end
  end

  defp request_agents(json?) do
    case Client.request("agents") do
      {:ok, %{"status" => "ok", "agents" => agents}} -> print_agents(agents, json?)
      {:ok, %{"status" => "error", "reason" => reason}} -> error(reason)
      {:ok, other} -> unexpected(other)
      {:error, :not_running} -> not_running()
      {:error, reason} -> error(reason)
    end
  end

  defp print_agents(agents, true) do
    IO.puts(Jason.encode!(agents))
    0
  end

  defp print_agents(agents, false) do
    main = Map.get(agents, "main", %{})
    counts = Map.get(agents, "counts", %{})

    IO.puts("main: #{main_health(main)}")
    IO.puts("main activity: #{main_activity(main)}")
    IO.puts("active requests: #{main_count(main, "active_requests", "active_conversations")}")
    IO.puts("pending requests: #{main_count(main, "pending_requests", "pending_conversations")}")
    IO.puts("skill workers: #{Map.get(counts, "skill_workers", 0)}")
    IO.puts("running skill workers: #{Map.get(counts, "running_skill_workers", 0)}")
    0
  end

  defp invalid_options(invalid) do
    IO.puts(:stderr, "fermix agents: invalid options #{inspect(invalid)}")
    2
  end

  defp unexpected(reply) do
    IO.puts(:stderr, "fermix agents: unexpected reply: #{inspect(reply)}")
    1
  end

  defp not_running do
    IO.puts(:stderr, "fermix: not running")
    @not_running_exit
  end

  defp error(reason) do
    IO.puts(:stderr, "fermix agents: #{inspect(reason)}")
    1
  end

  defp main_health(main) do
    Map.get(main, "health") || Map.get(main, "status", "unknown")
  end

  defp main_activity(main) do
    Map.get(main, "activity") || Map.get(main, "status", "unknown")
  end

  defp main_count(main, preferred, legacy) do
    Map.get(main, preferred, Map.get(main, legacy, 0))
  end
end
