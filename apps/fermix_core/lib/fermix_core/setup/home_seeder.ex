defmodule FermixCore.Setup.HomeSeeder do
  @moduledoc """
  Seeds a home that has no `config.toml` yet, on the daemon's first boot.

  Until this ran, a first boot created the home's folders and nothing else: the
  config file and the prompt files (`IDENTITY.md`, `USER.md`, `SOUL.md` and
  the rest) were written only by the last screen of setup, so a first run that
  ended before it, which signing in from the app's Settings pane is one way to
  do, left the daemon on in-memory placeholders and readiness gated on values
  nobody wrote. The owner's rule (2026-09-27): the home and everything Fermix
  needs to run are seeded by the first boot, not by a screen.

  What it seeds is what the machine already knows (`Setup.MachineFacts`): the
  system time zone, the account's full name, and the product's default
  communication style. A fact the machine cannot provide is left unset, never
  invented, and `Readiness` says so. The write goes through
  `Setup.Wizard.save_answers/2`, the path every save takes, so the config file,
  the applied environment and the prompt files come out exactly as a setup
  save leaves them, and About you in the app or the CLI prefills from the
  seeded values and edits them like any other save.

  A synchronous `:ignore` child, the `Capabilities.BuiltinSeeder` shape. It is
  listed after `Prompt.TemplateReconciler`, because the prompt seed needs the
  resource registry and the memory repo, and before `Setup.RestartState` and
  `Setup.BootReport`, so both baselines and the boot report see the seeded
  file rather than a change made behind their backs. A home whose config
  exists is left alone: this runs once, and never reconciles a chosen value
  against the machine on a later boot. A failure is logged and never takes the
  tree down: a daemon on placeholders beats no daemon.
  """

  alias FermixCore.Management.Settings.Assistant
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.MachineFacts
  alias FermixCore.Setup.Wizard

  require Logger

  # `mix test` boots the umbrella with a home of its own and every test
  # establishes the config it asserts; a boot-time seed there would write into
  # the suite's home behind every test's back. `run/0` is tested directly.
  @compiled_env Mix.env()

  @type outcome :: {:seeded, keyword()} | :existing | {:error, term()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  @spec start_link(keyword()) :: :ignore
  def start_link(_opts \\ []) do
    if @compiled_env != :test, do: run_or_log()
    :ignore
  end

  # The promise above: whatever a first boot's seed does, the tree comes up.
  defp run_or_log do
    run()
  rescue
    exception -> log_escape("raised", Exception.message(exception))
  catch
    kind, reason -> log_escape(Atom.to_string(kind), inspect(reason))
  end

  defp log_escape(how, detail) do
    Logger.error(
      "home seed #{how} on first boot: #{detail}; the daemon runs on placeholders until a setup save lands"
    )
  end

  @doc "Seeds the home when it carries no config, and reports what happened."
  @spec run() :: outcome()
  def run do
    if File.exists?(ConfigStore.path()), do: :existing, else: seed()
  end

  defp seed do
    answers = machine_answers()

    case Wizard.save_answers(Wizard.report().wizard, answers) do
      {:ok, report} ->
        Logger.info(
          "home seeded on first boot: #{Enum.map_join(answers, ", ", &Atom.to_string(elem(&1, 0)))}; " <>
            "#{length(report.seeding_results)} prompt files written"
        )

        {:seeded, answers}

      {:error, reason} ->
        Logger.error(
          "home seed failed on first boot: #{inspect(reason)}; " <>
            "the daemon runs on placeholders until a setup save lands"
        )

        {:error, reason}
    end
  end

  defp machine_answers do
    [
      user_name: fact(MachineFacts.full_name(), :user_name),
      timezone: fact(MachineFacts.timezone(), :timezone),
      communication_style: Assistant.default_style()
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fact({:ok, value}, _key), do: value

  defp fact(:error, key) do
    Logger.warning("home seed: the machine gave no #{key}; left unset for setup to ask")
    nil
  end
end
