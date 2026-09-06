defmodule FermixCore.Management.Meetings do
  @moduledoc """
  `meetings.signin.start`: the one-time interactive Google sign-in the meeting
  notetaker needs (M34 native setup §7.3).

  It is a job because it waits for a person at a headed browser. The sign-in
  state ends up inside the notetaker's own browser profile; the daemon never
  reads inside it and never sees a credential, only that a sign-in finished.

  Refused before it starts unless both halves of the notetaker are installed: a
  sign-in with no sidecar has nothing to launch, and one with no browser has
  nothing to launch it in.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Management.Jobs
  alias FermixCore.Meetings.SidecarInstaller
  alias FermixCore.Meetings.SignIn

  require Logger

  @not_installed "Install the meeting notetaker first; the sign-in needs it."
  @no_browser "The notetaker's browser is not installed yet, so the sign-in cannot launch."

  @type error :: {:unavailable, String.t()} | {:busy, String.t()}

  @doc "Starts the interactive sign-in, single-flight."
  @spec signin_start(keyword()) :: {:ok, map()} | {:error, error()}
  def signin_start(opts \\ []) when is_list(opts), do: start_signin(opts)

  # The install check runs inside the run rather than before it, so its refusal
  # reaches the operator as the job's own sentence. A request-level refusal
  # would only carry a capability name, and "install the notetaker first" is the
  # whole of the answer.
  defp installed(opts) do
    installed? = Keyword.get(opts, :installed?, &SidecarInstaller.installed?/0)
    browser? = Keyword.get(opts, :browser_installed?, &SidecarInstaller.browser_installed?/0)

    cond do
      not installed?.() -> {:error, {:unavailable, @not_installed}}
      not browser?.() -> {:error, {:unavailable, @no_browser}}
      true -> :ok
    end
  end

  defp start_signin(opts) do
    started =
      Jobs.start(
        :meetings_signin,
        Keyword.merge(Keyword.get(opts, :jobs, []),
          name: "meetings",
          run: signin_run(opts)
        )
      )

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, "meetings_signin"}}
    end
  end

  defp signin_run(opts) do
    signin = Keyword.get(opts, :signin, &SignIn.run/0)

    fn _job_id, report ->
      with :ok <- installed(opts) do
        report.({:phase, "awaiting_signin"})
        finish(signin.())
      end
    end
  end

  defp finish({:ok, :signed_in}), do: {:ok, %{"signed_in" => true}}
  defp finish({:error, reason}), do: {:error, {:unavailable, sentence(reason)}}

  defp sentence(:cancelled), do: "The sign-in window was closed before it finished."
  defp sentence(:timeout), do: "The sign-in was not completed in time."
  defp sentence(:not_installed), do: @not_installed

  defp sentence({:signin_failed, _status}),
    do: "The notetaker reported that the sign-in failed."

  defp sentence({:spawn_failed, _binary}),
    do: "The sign-in window could not be opened."

  defp sentence({:disclaim_shim_missing, _message}),
    do: "A helper this sign-in needs is missing from this install."

  # The residue. What is left is the notetaker's own internal term, which names
  # files on the operator's disk; it goes to the daemon log rather than to the
  # sentence a client renders.
  defp sentence(reason) do
    Logger.error("management meetings: the sign-in did not finish: #{Redaction.format(reason)}")
    "The sign-in did not finish. See the daemon log."
  end
end
