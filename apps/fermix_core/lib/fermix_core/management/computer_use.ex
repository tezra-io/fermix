defmodule FermixCore.Management.ComputerUse do
  @moduledoc """
  `computer_use.permissions.get` and `computer_use.grant.start`
  (M34 native setup §7.3).

  The read is non-prompting and the grant is not: they are two operations
  because raising the macOS dialogs is an act, and an act belongs behind a
  button rather than behind opening a pane. The read runs when the pane opens
  and when the operator asks for a refresh; the grant runs only when asked.

  `installed` is read from the installer rather than inferred from the probe:
  the feature being switched off says nothing about whether the helper is on
  disk, and the pane's install button keys off exactly that.

  A probed answer names the helper's `platform`. On Linux it adds the
  `display_server` and the rows `fermix doctor` prints after its `computer use`
  row (`Fermix.CLI.Doctor.Checks.linux_computer_use_rows/1`), because there the
  two booleans say what this session's pixel route serves and grant nothing.
  """

  alias Fermix.CLI.Doctor.Checks
  alias FermixCore.Auth.Redaction
  alias FermixCore.ComputerUse.Grant
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Management.Jobs
  alias FermixCore.Setup.Doctor

  require Logger

  @type error :: {:unavailable, String.t()} | {:busy, String.t()}

  @doc "The current, non-prompting permission state."
  @spec permissions(keyword()) :: {:ok, map()} | {:error, error()}
  def permissions(opts \\ []) when is_list(opts) do
    probe = Keyword.get(opts, :probe, &Doctor.computer_use_permissions/0)
    installed? = Keyword.get(opts, :installed?, &SidecarInstaller.installed?/0)

    case probe.() do
      {:ok, state} ->
        {:ok, project(state, installed?)}

      # A request-path refusal names a capability, not a sentence, so the reason
      # is logged rather than dropped.
      {:error, reason} ->
        Logger.error("management computer use probe refused: #{Redaction.format(reason)}")
        {:error, {:unavailable, "computer_use_permissions"}}
    end
  end

  @doc "Raises the OS permission prompts and answers with what was granted."
  @spec grant_start(keyword()) :: {:ok, map()} | {:error, error()}
  def grant_start(opts \\ []) when is_list(opts) do
    started =
      Jobs.start(
        :computer_use_grant,
        Keyword.merge(Keyword.get(opts, :jobs, []),
          name: "computer_use",
          run: grant_run(Keyword.get(opts, :grant, &Grant.request/0))
        )
      )

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, "computer_use_grant"}}
    end
  end

  defp grant_run(grant) do
    fn _job_id, _report ->
      case grant.() do
        {:ok, %{screen_capture: screen?, input_control: input?}} ->
          {:ok, %{"screen_capture" => screen?, "input_control" => input?}}

        {:error, reason} ->
          {:error, {:unavailable, grant_sentence(reason)}}
      end
    end
  end

  # Only an answer that probed the helper names its platform, so a state that
  # probed nothing answers exactly as it always has.
  defp project(%{state: :probed} = state, _installed?) do
    view(true, Map.fetch!(state, :screen_capture), Map.fetch!(state, :input_control), now())
    |> Map.put("platform", Map.fetch!(state, :platform))
    |> Map.merge(linux_view(state))
  end

  defp project(%{state: :not_installed}, _installed?), do: view(false, false, false, nil)

  # Switched off is not the same as absent: the helper may well be installed,
  # and the pane needs to know which of "install it" or "turn it on" to offer.
  defp project(%{state: :disabled}, installed?), do: view(installed?.(), false, false, nil)

  defp view(installed?, screen?, input?, probed_at) do
    %{
      "installed" => installed?,
      "screen_capture" => screen?,
      "input_control" => input?,
      "probed_at" => probed_at
    }
  end

  # On Linux nothing is granted, so the two booleans say what this session's
  # pixel route serves. The display server names the session's display, not its
  # route, and the rows (the pixel route among them) are the doctor's own, from
  # its producer, so the pane and `fermix doctor` cannot disagree.
  defp linux_view(%{platform: "linux"} = state) do
    %{
      "display_server" => Map.fetch!(state, :display_server),
      "rows" => Enum.map(Checks.linux_computer_use_rows({:ok, state}), &wire_row/1)
    }
  end

  defp linux_view(_state), do: %{}

  defp wire_row(%{name: name, status: status, detail: detail}),
    do: %{"name" => name, "status" => Atom.to_string(status), "detail" => detail}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp grant_sentence(:not_installed), do: "Fermix Computer Use is not installed yet."

  defp grant_sentence({:lsregister_failed, _code, _output}),
    do: "The helper could not be registered with this Mac, so the prompts never appeared."

  # The helper and the engine ship as one release and the handshake refuses a
  # mismatch, so this is not a prompt that failed to appear: it is an install
  # the update will replace. The two protocol numbers are a diagnosis rather
  # than copy, so they stay in the daemon log.
  defp grant_sentence({:protocol_mismatch, _versions} = reason) do
    log_refusal(reason)

    "Fermix Computer Use on this Mac is from a different Fermix release. Update Fermix to raise the prompts."
  end

  # The residue. A driver reason carries the sidecar's own words and the path it
  # was spawned from, so it goes to the daemon log and the sentence stays fixed.
  defp grant_sentence(reason) do
    log_refusal(reason)
    "The permission prompts could not be raised. See the daemon log."
  end

  defp log_refusal(reason) do
    Logger.error("management computer use grant refused: #{Redaction.format(reason)}")
  end
end
