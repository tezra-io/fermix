defmodule Fermix.CLI.MachineOutput do
  @moduledoc """
  The one machine-mode envelope every `--json` verb prints (M38 §4.6).

      {"schema_version":1,"ok":true,"result":{…}}
      {"schema_version":1,"ok":false,"error":{"code":"…","sentence":"…"}}

  **Stdout carries the envelope and nothing else.** Progress and prose go to
  stderr, so a caller can decode one line without stripping anything first. The
  interface renders the code it decides on and the sentence it shows a person;
  it never parses a subprocess's prose to work out what happened.

  **One sentence per code, all of them here.** `sentence/2` is that table. A
  sentence names what an operator can do, carries no internal vocabulary, and
  names a path only when the operator has to act on that path. The specifics a
  sentence needs (the account, the path, the service manager's own words) arrive
  as `details`, so the words stay in this module and the caller supplies facts.
  """

  @schema_version 1

  @codes ~w(
    app_managed
    user_manager_unreachable
    linger_denied
    loginctl_absent
    no_identity
    invalid_home
    home_change_refused
    foreign_unit
    activation_timeout
    health_unavailable
    foreign_distribution
    service_unbound
    diagnostics_unavailable
    idle_restart_unavailable
    lifecycle_refused
    invalid_port
    config_write_failed
    systemctl_failed
    binding_write_failed
    daemon_running
    epoch_absent
    already_moved
    mark_moved_failed
    engine_stopped
    snapshots_refused
    home_status_unavailable
    enrollment_refused
    move_refused
    grants_refused
  )a

  @doc "Every error code this CLI can print, for the caller that renders them."
  @spec codes() :: [atom()]
  def codes, do: @codes

  @doc "The success envelope, encoded."
  @spec ok(term()) :: String.t()
  def ok(result) do
    Jason.encode!(%{"schema_version" => @schema_version, "ok" => true, "result" => result})
  end

  @doc "The failure envelope, encoded, with this code's own sentence."
  @spec error(atom(), keyword()) :: String.t()
  def error(code, details \\ []) when code in @codes and is_list(details) do
    Jason.encode!(%{
      "schema_version" => @schema_version,
      "ok" => false,
      "error" => %{"code" => Atom.to_string(code), "sentence" => sentence(code, details)}
    })
  end

  @doc """
  The operator sentence for one error code.

  Human mode prints this same sentence, so the two modes never disagree about
  what happened.
  """
  @spec sentence(atom(), keyword()) :: String.t()
  def sentence(code, details \\ [])

  def sentence(:app_managed, _details) do
    "The Fermix application owns this engine's background service. Use the " <>
      "application's own background service controls."
  end

  def sentence(:user_manager_unreachable, _details) do
    "This session has no user service manager, so the background service cannot be " <>
      "inspected or changed from here. Log in to this machine and try again."
  end

  def sentence(:linger_denied, details) do
    "The background service has to keep running after you log out, and this machine " <>
      "refused to allow that. Run sudo loginctl enable-linger #{account(details)}, then " <>
      "try again." <> said(details)
  end

  def sentence(:loginctl_absent, _details) do
    "This machine has no loginctl, so Fermix cannot keep the background service running " <>
      "after you log out. Run the daemon in the foreground with fermix run instead."
  end

  def sentence(:no_identity, _details) do
    "Fermix could not tell which account it is running as, and it will not guess one. " <>
      "Run this command from a normal login session."
  end

  def sentence(:invalid_home, details), do: reason(details)

  def sentence(:home_change_refused, details) do
    "The background service is running from #{account_home(details)}. Stop it with " <>
      "fermix service uninstall before moving it to another home."
  end

  def sentence(:foreign_unit, details) do
    "Fermix did not write the service file at #{path(details)}, so it was left alone. " <>
      "Remove or rename it if you want Fermix to manage this service."
  end

  def sentence(:activation_timeout, _details) do
    "The background service was started but did not answer in time. Read what it said " <>
      "with journalctl --user -u fermix, then try again."
  end

  def sentence(:health_unavailable, _details) do
    "The background service is running, but its web address did not answer, so the " <>
      "setup page is not reachable yet. Read what it said with journalctl --user -u fermix."
  end

  def sentence(:foreign_distribution, _details) do
    "This Fermix was not installed from a Linux package, so there is no packaged " <>
      "background service for it to manage."
  end

  def sentence(:service_unbound, _details) do
    "No home is bound to the background service yet. Run fermix service install to " <>
      "choose one."
  end

  def sentence(:diagnostics_unavailable, details) do
    "Fermix could not collect the diagnostic bundle." <> said(details)
  end

  def sentence(:idle_restart_unavailable, _details) do
    "This engine cannot restart when idle yet. Restarting now interrupts any work in " <>
      "progress."
  end

  def sentence(:lifecycle_refused, details) do
    "The background service would not open a window to restart in." <> said(details)
  end

  def sentence(:invalid_port, details), do: reason(details)

  def sentence(:config_write_failed, details) do
    "Fermix could not record the web listener port in the settings file." <> said(details)
  end

  def sentence(:systemctl_failed, details) do
    "The service manager refused the change." <> said(details)
  end

  def sentence(:binding_write_failed, details) do
    "Fermix could not record which home the background service runs from." <> said(details)
  end

  def sentence(:daemon_running, _details),
    do: "Fermix is running from this home. Stop it, then try again."

  def sentence(:epoch_absent, _details),
    do: "The home has no primary epoch: it has never started as the primary."

  def sentence(:already_moved, details) do
    "This home already moved to #{Keyword.fetch!(details, :to)} on " <>
      "#{Keyword.fetch!(details, :date)} at epoch #{Keyword.fetch!(details, :epoch)}, and the " <>
      "first move stands."
  end

  def sentence(:mark_moved_failed, details),
    do: "Fermix could not mark this home moved." <> said(details)

  def sentence(:engine_stopped, _details),
    do: "Fermix is not running from this home, and this needs it. Start it, then try again."

  def sentence(:snapshots_refused, details),
    do: "Fermix did not do that." <> said(details)

  def sentence(:home_status_unavailable, details),
    do: "Fermix could not read this home's status." <> said(details)

  def sentence(:enrollment_refused, details),
    do: "Fermix did not open an enrollment code." <> said(details)

  def sentence(:move_refused, details),
    do: "Fermix did not start the move." <> said(details)

  def sentence(:grants_refused, details),
    do: "Fermix did not do that on this computer." <> said(details)

  defp said(details) do
    case Keyword.get(details, :output) do
      output when is_binary(output) and output != "" -> " It said: #{output}"
      _absent -> ""
    end
  end

  defp reason(details), do: Keyword.fetch!(details, :reason)
  defp path(details), do: Keyword.fetch!(details, :path)
  defp account(details), do: Keyword.get(details, :user, "USER")
  defp account_home(details), do: Keyword.fetch!(details, :home)
end
