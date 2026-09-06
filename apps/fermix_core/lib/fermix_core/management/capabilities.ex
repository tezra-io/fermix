defmodule FermixCore.Management.Capabilities do
  @moduledoc """
  `capabilities.install.start`: the downloads a setup surface can start
  (M34 native setup §7.3).

  Three targets, one job kind. Each is idempotent — an installed half
  short-circuits — so re-running an install after a failure resumes rather than
  starting over, and each is single-flight per target so two panes cannot
  download the same helper twice.

  Refusals are the installer's own words. A target with no pinned release for
  this machine says so; it never downloads something unpinned.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.ComputerUse.SidecarInstaller, as: ComputerUseInstaller
  alias FermixCore.Management.Jobs
  alias FermixCore.Meetings.BrowserInstall
  alias FermixCore.Meetings.SidecarInstaller, as: MeetbotInstaller
  alias FermixCore.Transcription.Local, as: LocalTranscription

  require Logger

  @targets ~w(computer_use_sidecar meetbot local_stt)

  @type error :: {:invalid_params, String.t(), String.t()} | {:busy, String.t()}

  @doc "Every capability this daemon can install, ordered."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc "Starts one install, single-flight per target."
  @spec install_start(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def install_start(target, opts \\ []) when is_binary(target) and is_list(opts) do
    if target in @targets do
      start_install(target, opts)
    else
      {:error, {:invalid_params, "target", "This daemon cannot install that."}}
    end
  end

  defp start_install(target, opts) do
    started =
      Jobs.start(
        :capability_install,
        Keyword.merge(Keyword.get(opts, :jobs, []),
          name: target,
          run: install_run(target, opts)
        )
      )

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, "capability_install"}}
    end
  end

  defp install_run("computer_use_sidecar", opts) do
    install = Keyword.get(opts, :install, &ComputerUseInstaller.install/0)

    fn _job_id, report ->
      report.({:phase, "sidecar_downloading"})
      done("computer_use_sidecar", install.())
    end
  end

  # Two halves, one target: the sidecar binary and the version-matched browser
  # it launches. A meeting join needs both, so an install that stops after the
  # first would report a capability that cannot run.
  defp install_run("meetbot", opts) do
    install = Keyword.get(opts, :install, &MeetbotInstaller.install/0)
    install_browser = Keyword.get(opts, :install_browser, &BrowserInstall.run/0)

    fn _job_id, report ->
      report.({:phase, "sidecar_downloading"})

      case install.() do
        {:ok, _path} -> install_meetbot_browser(install_browser, report)
        {:error, reason} -> {:error, {:unavailable, meetbot_sentence(reason)}}
      end
    end
  end

  defp install_run("local_stt", opts) do
    install = Keyword.get(opts, :install, &LocalTranscription.ensure_installed/1)

    fn _job_id, report ->
      done("local_stt", install.(progress: local_progress(report)))
    end
  end

  defp install_meetbot_browser(install_browser, report) do
    report.({:phase, "downloading"})
    done("meetbot", install_browser.())
  end

  # The on-device backend installs a sidecar and then a model. The two stages
  # are the two phases: nothing here invents byte progress the installers do not
  # report.
  defp local_progress(report) do
    fn
      {:sidecar, :downloading} -> report.({:phase, "sidecar_downloading"})
      {:sidecar, :done} -> report.({:phase, "downloading"})
      _stage -> :ok
    end
  end

  defp done(target, :ok), do: {:ok, installed(target)}
  defp done(target, {:ok, _value}), do: {:ok, installed(target)}
  defp done(_target, {:error, reason}), do: {:error, {:unavailable, sentence(reason)}}

  defp installed(target), do: %{"target" => target, "installed" => true}

  defp meetbot_sentence(:no_pinned_release),
    do: MeetbotInstaller.error_message(:no_pinned_release)

  defp meetbot_sentence({:unsupported_target, target}),
    do: "There is no meeting notetaker build for this machine (#{target})."

  defp meetbot_sentence(reason), do: sentence(reason)

  defp sentence(:not_installed),
    do: "The helper this step needs is not installed yet."

  defp sentence(:no_release_pinned),
    do: "This build pins no release of that helper yet."

  defp sentence({:no_pinned_artifact, _tag, _target}),
    do: "The pinned release carries no build for this Mac."

  defp sentence({:checksum_mismatch, _expected, _actual}),
    do: "The download did not match the checksum it was published with."

  defp sentence({:sha256_mismatch, _detail}),
    do: "The download did not match the checksum it was published with."

  defp sentence(:model_pins_missing),
    do: "This build pins no checksums for that model, so it will not download it."

  defp sentence({:unknown_model, _engine, _model}),
    do: "This build does not know the model that step asked for."

  defp sentence(:timeout),
    do: "The download did not finish in time."

  defp sentence({:spawn_failed, _binary}),
    do: "The installer could not be started."

  defp sentence({:browser_install_failed, _status}),
    do: "The notetaker's browser could not be installed."

  # The residue. Everything above is a refusal this daemon can explain; what is
  # left is an installer's internal term, which carries the operator's own
  # paths. It goes to the daemon log, never to the wire.
  defp sentence(reason) do
    Logger.error(
      "management capabilities: the install did not finish: " <>
        Redaction.format(reason)
    )

    "The install did not finish. See the daemon log."
  end
end
