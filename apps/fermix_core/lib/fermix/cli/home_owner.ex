defmodule Fermix.CLI.HomeOwner do
  @moduledoc """
  Whether *this home* is managed by Fermix.app (M34 native setup §15.2, §7.6).

  Distinct from `FermixCore.BuildInfo.app_engine?/0`, which asks whether *this
  binary* is the app engine. A Homebrew binary sitting beside an installed app
  answers that predicate false, so the existing guards never fire on it, and it
  would happily install, start or stop a service the app owns.

  **A decision table over two disjoint states, not a precedence chain.** When a
  daemon answers on `daemon.sock`, its `hello` decides and the marker is not
  read. When no daemon answers, the marker decides, and only while the bundle it
  records still exists. One source per state; there is no second attempt after a
  first one fails.

  **The check fails open.** A machine with no app, no daemon and no marker
  answers false, so every verb behaves exactly as it does today.

  **Ordering.** Callers consult this only where no `BuildInfo.app_engine?/0`
  branch already answers. The app's own binary keeps its existing routed verbs
  and its own lifecycle restart untouched; this check's only subject is a
  formula binary pointed at an app-managed home.
  """

  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Setup.EngineOwner

  @app_identity "macos_app"

  @doc """
  Whether this home is managed by Fermix.app.

  `:hello` and `:marker?` are injectable so both states of the table are
  testable without a socket or a bundle on disk.
  """
  @spec app_managed?(keyword()) :: boolean()
  def app_managed?(opts \\ []) when is_list(opts) do
    hello = Keyword.get(opts, :hello, fn -> Client.request_v1("hello", %{}, opts) end)

    case hello.() do
      {:ok, %{"engine" => %{"distribution_identity" => identity}}} -> identity == @app_identity
      _no_daemon -> marker_says_app_managed?(opts)
    end
  end

  @doc """
  The sentence a refused verb prints.

  Names the app rather than a command: the operator's next action is in the app,
  and the CLI cannot know which of the app's controls they need.
  """
  @spec refusal_sentence(String.t()) :: String.t()
  def refusal_sentence(verb) when is_binary(verb) do
    "`#{verb}` is not available: this Fermix home is managed by Fermix.app. " <>
      "Use the app's background service controls."
  end

  defp marker_says_app_managed?(opts) do
    marker? = Keyword.get(opts, :marker?, &EngineOwner.app_managed_marker?/1)
    marker?.(opts)
  end
end
