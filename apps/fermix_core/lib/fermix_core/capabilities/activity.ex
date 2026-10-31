defmodule FermixCore.Capabilities.Activity do
  @moduledoc """
  What a person reads while a tool runs: one sentence for the step a turn is
  on, in their words and never the tool's name. The Mac's chat shows it under
  its thinking line (companion protocol 6, `tool_event.activity`).

  The one owner of those sentences. One rule picks a call's, from the
  capability the call names:

    * a built-in Fermix ships says its own (`builtin_sentences/0`; a test holds
      every built-in the seeder can register to having one);
    * a tool a plugin brings says `Using <plugin>`, by the plugin's display
      name, and a tool of an MCP server the owner added says `Using <server>`,
      by the name the owner gave it (`[mcp.servers.<name>]`);
    * anything else, a skill or a name no capability has, says
      `Working on it`.

  A sentence is sentence case, with no final period, and at most
  `Companion.Protocol.max_activity_bytes/0` bytes: a long display name is cut
  on a character.
  """

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry
  alias FermixCore.Companion.Protocol
  alias FermixCore.Text

  @plain "Working on it"

  @sentences %{
    "shell" => "Running a command",
    "file_read" => "Reading a file",
    "view_image" => "Looking at an image",
    "file_write" => "Writing a file",
    "file_edit" => "Editing a file",
    "glob_search" => "Looking through your files",
    "content_search" => "Searching your files",
    "git_read" => "Looking at a repository",
    "git_write" => "Saving changes to a repository",
    "web_fetch" => "Reading a web page",
    "web_search" => "Searching the web",
    "place_search" => "Looking up places",
    "recall_activity" => "Looking back at what you were working on",
    "voice_call_context" => "Going over what was said on the call",
    "tool_result_recall" => "Going back over an earlier result",
    "skill_create" => "Writing a new skill",
    "skill_reload" => "Reloading skills",
    "skill_view" => "Reading a skill",
    "skill_run" => "Running a skill",
    "skill_list" => "Looking through skills",
    "subagents" => "Handing parts of the work to helpers",
    "request_directory_access" => "Asking for access to a folder",
    "model_routing_config" => "Changing which models do what",
    "tool_help" => "Checking how a tool works",
    "tool_search" => "Looking for the right tool",
    "tool_describe" => "Checking how a tool works",
    "tool_call" => @plain,
    "memory_recall" => "Looking through memories",
    "memory_store" => "Saving a memory",
    "memory_forget" => "Forgetting a memory",
    "memory_sources_list" => "Looking at where memories come from",
    "schedule_job" => "Scheduling a task",
    "update_job" => "Changing a scheduled task",
    "list_jobs" => "Looking at scheduled tasks",
    "pause_job" => "Pausing a scheduled task",
    "resume_job" => "Resuming a scheduled task",
    "remove_job" => "Removing a scheduled task",
    "run_job_now" => "Running a scheduled task now",
    "list_job_runs" => "Looking at a task's past runs",
    "get_job_run" => "Reading how a task's run went",
    "browser" => "Working on a website",
    "send_attachment" => "Attaching a file",
    "react" => "Adding a reaction",
    "send_to_channel" => "Sending you a message in another app",
    "generate_image" => "Making an image",
    "computer_use" => "Using the computer",
    "codex_run" => "Asking Codex",
    "claude_code_run" => "Asking Claude Code",
    "codex_cloud_run" => "Asking Codex in the cloud",
    "list_coding_runs" => "Looking at coding runs",
    "get_coding_run" => "Checking on a coding run",
    "cancel_coding_run" => "Stopping a coding run",
    "stop_tracking_coding_run" => "No longer following a coding run",
    "event_store" => "Saving a reminder",
    "event_list" => "Checking your reminders and events",
    "event_update" => "Changing a reminder",
    "event_remove" => "Removing a reminder",
    "reminder_snooze" => "Snoozing a reminder",
    "open_loop_note" => "Noting something to follow up on",
    "open_loop_update" => "Updating something to follow up on",
    "open_loop_list" => "Looking at what to follow up on",
    "open_loop_respond" => "Answering a follow-up",
    "join_meeting" => "Joining a meeting",
    "leave_meeting" => "Leaving a meeting",
    "list_meetings" => "Looking at meetings",
    "manage_watcher" => "Changing a watcher",
    "list_cues" => "Looking at what your watchers received",
    "cue_history" => "Looking at what this watcher received before"
  }

  @doc """
  The sentence for a call of `name`, as the capability `server` holds under
  that name says it (moduledoc).
  """
  @spec sentence(GenServer.server(), String.t()) :: String.t()
  def sentence(server \\ Registry, name) when is_binary(name) do
    case Registry.find(server, name) do
      {:ok, capability} -> of(capability)
      :error -> @plain
    end
  end

  @doc "Every built-in's own sentence, by the built-in's name."
  @spec builtin_sentences() :: %{String.t() => String.t()}
  def builtin_sentences, do: @sentences

  @doc "What a step says when nothing more particular is known."
  @spec plain() :: String.t()
  def plain, do: @plain

  defp of(%Capability{metadata: %{plugin_display_name: name}}) when is_binary(name),
    do: using(name)

  defp of(%Capability{kind: :mcp, metadata: %{mcp_server: server}}) when is_binary(server),
    do: using(server)

  defp of(%Capability{kind: :builtin, name: name}), do: Map.get(@sentences, name, @plain)

  defp of(%Capability{}), do: @plain

  defp using(name), do: Text.truncate_utf8("Using " <> name, Protocol.max_activity_bytes())
end
