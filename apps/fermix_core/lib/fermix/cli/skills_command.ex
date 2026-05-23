defmodule Fermix.CLI.SkillsCommand do
  @moduledoc """
  `fermix skills` — list, view, and reload installed skills.
  """

  alias Fermix.CLI.Daemon.Client

  @not_running_exit 3

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case argv do
      [] -> list([])
      ["list" | rest] -> list(rest)
      ["view", name | rest] -> view(name, rest)
      ["reload" | rest] -> reload(rest)
      _other -> usage()
    end
  end

  defp list(argv) do
    case parse_json_opts(argv) do
      {:ok, json?} -> request_list(json?)
      :error -> invalid_options()
    end
  end

  defp view(name, argv) do
    case parse_json_opts(argv) do
      {:ok, json?} -> request_view(name, json?)
      :error -> invalid_options()
    end
  end

  defp reload(argv) do
    case parse_json_opts(argv) do
      {:ok, json?} -> request_reload(json?)
      :error -> invalid_options()
    end
  end

  defp request_list(json?) do
    case Client.request("skills_list") do
      {:ok, %{"status" => "ok", "skills" => skills}} -> print_list(skills, json?)
      {:ok, %{"status" => "error", "reason" => reason}} -> error(reason)
      {:ok, other} -> unexpected(other)
      {:error, :not_running} -> not_running()
      {:error, reason} -> error(reason)
    end
  end

  defp request_view(name, json?) do
    case Client.request("skills_view", params: %{"name" => name}) do
      {:ok, %{"status" => "ok", "skill" => skill}} -> print_view(skill, json?)
      {:ok, %{"status" => "error", "reason" => reason}} -> error(reason)
      {:ok, other} -> unexpected(other)
      {:error, :not_running} -> not_running()
      {:error, reason} -> error(reason)
    end
  end

  defp request_reload(json?) do
    case Client.request("skills_reload", timeout: 10_000) do
      {:ok, %{"status" => "ok", "reload" => reload}} -> print_reload(reload, json?)
      {:ok, %{"status" => "error", "reason" => reason}} -> error(reason)
      {:ok, other} -> unexpected(other)
      {:error, :not_running} -> not_running()
      {:error, reason} -> error(reason)
    end
  end

  defp print_list(skills, true) do
    IO.puts(Jason.encode!(skills))
    0
  end

  defp print_list(skills, false) do
    IO.puts("skills: #{Map.get(skills, "count", 0)}")
    skills |> Map.get("skills", []) |> Enum.each(&print_skill_row/1)
    print_errors(Map.get(skills, "errors", []))
    0
  end

  defp print_view(skill, true) do
    IO.puts(Jason.encode!(skill))
    0
  end

  defp print_view(skill, false) do
    IO.puts("# #{Map.get(skill, "name")}")
    IO.puts(Map.get(skill, "description", ""))
    IO.puts("trust: #{Map.get(skill, "trust")}")
    IO.puts("path: #{Map.get(skill, "source_path")}")
    IO.puts("")
    IO.puts(Map.get(skill, "body", ""))
    0
  end

  defp print_reload(reload, true) do
    IO.puts(Jason.encode!(reload))
    0
  end

  defp print_reload(reload, false) do
    IO.puts("skills reloaded: #{Map.get(reload, "count", 0)}")
    print_change("added", Map.get(reload, "added", []))
    print_change("removed", Map.get(reload, "removed", []))
    print_change("changed", Map.get(reload, "changed", []))
    print_errors(Map.get(reload, "errors", []))
    0
  end

  defp print_skill_row(row) do
    IO.puts("- #{Map.get(row, "name")} [#{Map.get(row, "trust")}] #{Map.get(row, "description")}")
  end

  defp print_change(_label, []), do: :ok
  defp print_change(label, values), do: IO.puts("#{label}: #{Enum.join(values, ", ")}")

  defp print_errors([]), do: :ok

  defp print_errors(errors) do
    IO.puts("errors: #{length(errors)}")
    Enum.each(errors, &IO.puts("- #{&1}"))
  end

  defp parse_json_opts(argv) do
    case OptionParser.parse(argv, strict: [json: :boolean]) do
      {opts, [], []} -> {:ok, Keyword.get(opts, :json, false)}
      {_opts, _args, _invalid} -> :error
    end
  end

  defp usage do
    IO.puts(:stderr, "usage: fermix skills [list|view NAME|reload] [--json]")
    2
  end

  defp invalid_options do
    IO.puts(:stderr, "fermix skills: invalid options")
    2
  end

  defp unexpected(reply) do
    IO.puts(:stderr, "fermix skills: unexpected reply: #{inspect(reply)}")
    1
  end

  defp not_running do
    IO.puts(:stderr, "fermix: not running")
    @not_running_exit
  end

  defp error(reason) do
    IO.puts(:stderr, "fermix skills: #{inspect(reason)}")
    1
  end
end
