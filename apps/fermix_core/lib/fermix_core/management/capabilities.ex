defmodule FermixCore.Management.Capabilities do
  @moduledoc """
  `capabilities.install.start` and `browser.install.start`: the downloads a
  setup surface can start (M34 native setup §7.3).

  Four targets, one job kind. Each is idempotent — an installed half
  short-circuits — so re-running an install after a failure resumes rather than
  starting over, and each is single-flight per target so two panes cannot
  download the same helper twice.

  The browser download is its own kind because its answer is different: it
  runs the notetaker's install step (the helper, then its version-matched
  Chromium) and then asks the launcher which browser tasks now run in, so a
  download the launcher still cannot find is a failure rather than a green
  check over a pane that says there is no browser.

  Refusals are the installer's own words. A target with no pinned release for
  this machine says so; it never downloads something unpinned.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.ComputerUse.SidecarInstaller, as: ComputerUseInstaller
  alias FermixCore.IMessage.HelperInstaller, as: IMessageHelper
  alias FermixCore.Management.Jobs
  alias FermixCore.Meetings.BrowserInstall
  alias FermixCore.Meetings.SidecarInstaller, as: MeetbotInstaller
  alias FermixCore.Transcription.Local, as: LocalTranscription
  alias FermixCore.Transcription.Local.SidecarInstaller, as: LocalSttInstaller

  require Logger

  @targets ~w(computer_use_sidecar meetbot local_stt imessage_helper)

  @no_chromium_build "Fermix has no Chromium download for this machine."
  @browser_still_missing "The download finished, but Fermix still finds no browser to run " <>
                           "tasks in. See the daemon log."

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

  @doc """
  Starts the download of a browser for tasks, single-flight.

  The same two steps the notetaker's install takes, then the launcher's own
  answer: the result names the browser tasks now run in. `opts` carries the
  test seams `install`, `install_browser` and `resolve`.
  """
  @spec browser_install_start(keyword()) :: {:ok, map()} | {:error, error()}
  def browser_install_start(opts \\ []) when is_list(opts) do
    started =
      Jobs.start(
        :browser_install,
        Keyword.merge(Keyword.get(opts, :jobs, []), name: "browser", run: browser_run(opts))
      )

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, "browser_install"}}
    end
  end

  defp browser_run(opts) do
    install = Keyword.get(opts, :install, &MeetbotInstaller.install/0)
    install_browser = Keyword.get(opts, :install_browser, &BrowserInstall.run/0)
    resolve = Keyword.get(opts, :resolve, &ChromeLauncher.resolve_default/0)

    fn _job_id, report ->
      report.({:phase, "sidecar_downloading"})

      case install.() do
        {:ok, _path} -> download_chromium(install_browser, resolve, report)
        {:error, reason} -> {:error, {:unavailable, browser_sentence(reason)}}
      end
    end
  end

  defp download_chromium(install_browser, resolve, report) do
    report.({:phase, "downloading"})

    case install_browser.() do
      {:ok, _outcome} -> browser_found(resolve.())
      {:error, reason} -> {:error, {:unavailable, browser_sentence(reason)}}
    end
  end

  # The install is judged by what the launcher can now start, never by the
  # installer's exit status alone.
  defp browser_found({:ok, %{label: label}}),
    do: {:ok, %{"installed" => true, "browser" => label}}

  defp browser_found({:error, %{code: "chrome_missing"}}) do
    Logger.error("management capabilities: the browser download finished and no browser resolves")

    {:error, {:unavailable, @browser_still_missing}}
  end

  defp browser_found({:error, _refused} = refused),
    do: {:error, {:unavailable, ChromeLauncher.sentence(refused)}}

  # A machine the notetaker has no build for has no Chromium to download
  # either, and the browser step's own failure is named as the browser's.
  defp browser_sentence(:no_pinned_release), do: @no_chromium_build
  defp browser_sentence({:unsupported_target, _target}), do: @no_chromium_build
  defp browser_sentence({:no_pinned_artifact, _tag, _target}), do: @no_chromium_build

  defp browser_sentence({:browser_install_failed, _status}),
    do: "Chromium could not be installed."

  defp browser_sentence(reason), do: sentence(reason)

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

  # Setup does not offer on-device speech yet, and an install nobody can then
  # select would spend a long download on a backend that cannot be chosen, so
  # the job refuses in the same sentence the panes show.
  defp install_run("local_stt", opts) do
    install = Keyword.get(opts, :install, &LocalTranscription.ensure_installed/1)
    offered? = Keyword.get(opts, :offered?, LocalTranscription.offered?())

    fn _job_id, report ->
      if offered? do
        done("local_stt", install.(progress: local_progress(report)))
      else
        {:error, {:unavailable, LocalTranscription.unoffered_message()}}
      end
    end
  end

  # The Fermix Messages helper (M54 §10.2): one signed bundle, verified and
  # registered before it is placed, so a refusal names which check stopped it.
  defp install_run("imessage_helper", opts) do
    install = Keyword.get(opts, :install, &IMessageHelper.install/0)

    fn _job_id, report ->
      report.({:phase, "sidecar_downloading"})

      case install.() do
        {:ok, _path} -> {:ok, installed("imessage_helper")}
        {:error, reason} -> {:error, {:unavailable, imessage_sentence(reason)}}
      end
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

  defp imessage_sentence(:pin_not_set),
    do: "This Fermix build pins no Fermix Messages release yet, so there is nothing to install."

  defp imessage_sentence({:helper_unverified, _reason} = reason) do
    log_install_refusal(reason)
    "The download is not signed by Fermix, so it was not installed."
  end

  defp imessage_sentence({:unsupported_platform, :imessage}),
    do: "iMessage runs only on the Mac whose Messages it reads."

  defp imessage_sentence({:lsregister_failed, _code, _output} = reason) do
    log_install_refusal(reason)
    "Fermix Messages was installed but could not be registered with this Mac."
  end

  defp imessage_sentence(reason), do: sentence(reason)

  defp log_install_refusal(reason) do
    Logger.error("management capabilities: imessage_helper refused: #{Redaction.format(reason)}")
  end

  defp sentence(:not_installed),
    do: "The helper this step needs is not installed yet."

  # Only the on-device speech installer refuses this way, so it answers in the
  # words every other surface uses for a machine with no build.
  defp sentence(:no_release_pinned),
    do: LocalSttInstaller.error_message(:no_release_pinned)

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
