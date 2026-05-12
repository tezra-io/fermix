defmodule FermixCore.Prompt.Defaults do
  @moduledoc """
  In-memory rendered template content used as a read-side fallback when a
  bootstrap or memory file is missing on disk.

  Read-only. Never writes to disk. Never seeds memory rows. The setup-time
  seeder is the only path that writes prompt files; this module exists so
  the runtime has serviceable content before setup has run (test envs,
  fresh installs between application boot and wizard finalization).
  """

  alias FermixCore.Prompt.TemplateRenderer

  @placeholder_user_name "there"
  @placeholder_timezone "UTC"
  @placeholder_communication_style "neutral and direct"

  @spec identity_md() :: String.t()
  def identity_md do
    {:ok, content} = TemplateRenderer.render(:identity, %{agent_name: agent_name()})
    content
  end

  @spec agents_md() :: String.t()
  def agents_md do
    {:ok, content} = TemplateRenderer.render(:agents, %{})
    content
  end

  @spec soul_md() :: String.t()
  def soul_md do
    {:ok, content} = TemplateRenderer.render(:soul, %{})
    content
  end

  @spec user_md() :: String.t()
  def user_md do
    {:ok, content} =
      TemplateRenderer.render(:user, %{
        user_name: @placeholder_user_name,
        timezone: @placeholder_timezone,
        communication_style: @placeholder_communication_style
      })

    content
  end

  @spec memory_md() :: String.t()
  def memory_md do
    {:ok, content} = TemplateRenderer.render(:memory, %{})
    content
  end

  @spec realtime_md() :: String.t()
  def realtime_md do
    {:ok, content} = TemplateRenderer.render(:realtime, %{})
    content
  end

  defp agent_name do
    :fermix_core
    |> Application.get_env(:agent, [])
    |> Keyword.get(:name, "fermix")
  end
end
