defmodule FermixCore.Tools.SkillReload do
  @moduledoc """
  Re-scan the skill directories and refresh the live registry without a restart.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Tools.Support

  @impl true
  def name, do: "skill_reload"

  @impl true
  def description do
    "Re-scan the skill directories and refresh the running agent's skills " <>
      "without restarting the daemon. Use this after creating or editing a " <>
      "SKILL.md on disk (or installing a plugin that ships skills) so the new " <>
      "or changed skill becomes loadable in this session. Returns what changed: " <>
      "added, removed, changed names, and any load errors."
  end

  @impl true
  def parameters do
    %{type: "object", required: [], properties: %{}}
  end

  @impl true
  def when_to_use do
    "Pick up a newly created or edited skill (or a plugin's skills) in the running daemon without a restart."
  end

  @impl true
  def examples do
    [%{args: %{}, note: "reload skills after editing a SKILL.md on disk"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "reload_failed", description: "the skill registry could not be re-scanned"},
      %{tag: "agent_unavailable", description: "the main agent is not running"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :skill_admin

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(context) end)
  end

  defp do_execute(context) do
    server = Map.get(context, :main_agent_server, MainAgent)

    case MainAgent.reload_skills(server) do
      {:ok, summary} -> Support.success_json(reload_summary(summary))
      {:error, reason} -> Support.error("reload_failed: #{inspect(reason)}")
    end
  catch
    :exit, reason -> Support.error("agent_unavailable: #{inspect(reason)}")
  end

  # Shape the registry summary into a JSON-safe payload: errors hold tuples that
  # Jason cannot encode, so they are rendered to strings (mirrors the CLI
  # `fermix skills reload` reply shape).
  defp reload_summary(summary) do
    %{
      version: Map.get(summary, :version),
      count: length(Map.get(summary, :names, [])),
      names: Map.get(summary, :names, []),
      added: Map.get(summary, :added, []),
      removed: Map.get(summary, :removed, []),
      changed: Map.get(summary, :changed, []),
      errors: summary |> Map.get(:errors, []) |> Enum.map(&inspect/1)
    }
  end
end
