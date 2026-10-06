defmodule Fermix.CLI.SettingsCommand do
  @moduledoc """
  `fermix settings`: lists, shows and changes the running daemon's settings
  over the management protocol (`settings.*`, `secret.*`,
  `providers.set_primary`, `setup.state.get`).

  A daemon-only client. With no daemon it exits 3 and writes nothing itself: a
  tree-less VM has no restart-state baseline, so a local write would pass the
  outside-edit guard here and put the daemon into `external_change` (a second
  writer). It never restarts, never reloads on its own and never switches the
  secret store; it prints the remedy and leaves the step to the operator.

  Exit codes: 0 ok; 1 the daemon refused, the reply was invalid, the secret read
  failed or the home is app-managed; 2 usage, including a secret typed as an
  argument; 3 the daemon is not running.

  `--json` prints exactly one JSON object on stdout: the daemon's result, or an
  `{"error": ...}` object. Human sentences always go to stderr.

  Dependencies come in through `opts`: `:client` (default
  `Client.request_v1/3`), `:stdout`, `:stderr`, `:secret_input` (a keyword list
  handed to `SecretInput`) and `:app_managed?` (a zero-arity predicate, default
  `HomeOwner.app_managed?/0`). One request per call, no retries.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.HomeOwner
  alias Fermix.CLI.SecretInput
  alias Fermix.CLI.SettingsCommand.Args
  alias Fermix.CLI.SettingsCommand.Render

  # Reads: the section list, one section's rows, the provider list.
  @read_ms 10_000
  # A wizard write plus the readiness recompute, well above their observed cost.
  @write_ms 30_000
  # Above SecretWriter's 120 s unlock-prompt wait, so a locked keyring answers as
  # the daemon's own `secret_store_failed` timeout, not as this side's receive
  # timeout. One timeout covers connect and receive, so a wedged daemon makes a
  # secret call wait this long before it is reported.
  @secret_ms 130_000

  @type client :: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})

  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    deps = deps(opts)
    json? = "--json" in argv

    case Args.parse(argv) do
      {:usage, reason} -> usage(reason, json?, deps)
      {:secret_in_argv, form, key} -> secret_in_argv(form, key, json?, deps)
      command -> guarded(command, deps)
    end
  end

  # D4: an app-managed home's settings change in the app. The home-owner check
  # is the first daemon contact, so nothing is read or written before it.
  defp guarded(command, deps) do
    if deps.app_managed?.() do
      flags = elem(command, tuple_size(command) - 1)
      refuse(:app_managed, flags.json, context("fermix settings", :read, @read_ms), deps)
    else
      exec(command, deps)
    end
  end

  defp exec({:list, flags}, deps) do
    ctx = context("fermix settings", :read, @read_ms)

    deps
    |> call("settings.sections", %{}, @read_ms)
    |> emit(&Render.sections/1, flags, ctx, deps)
  end

  defp exec({:show, section, flags}, deps) do
    ctx = context("fermix settings", :read, @read_ms, section: section)

    deps
    |> call("settings.get", %{"section" => section}, @read_ms)
    |> emit(&Render.section(&1, flags.info), flags, ctx, deps)
  end

  defp exec({:set, section, pairs, flags}, deps), do: set_flow(section, pairs, flags, deps)
  defp exec({:secret_set, id, flags}, deps), do: secret_set_flow(id, flags, deps)

  defp exec({:secret_clear, id, flags}, deps) do
    ctx = context("fermix settings secret clear", :secret_clear, @secret_ms)

    deps
    |> call("secret.clear", %{"id" => id}, @secret_ms)
    |> emit(&Render.secret(&1, :clear), flags, ctx, deps)
  end

  defp exec({:primary, nil, flags}, deps) do
    ctx = context("fermix settings primary", :read, @read_ms)

    deps
    |> call("setup.state.get", %{}, @read_ms)
    |> emit(&Render.providers/1, flags, ctx, deps)
  end

  defp exec({:primary, provider, flags}, deps) do
    ctx = context("fermix settings primary", :change, @write_ms, check: "fermix settings primary")

    deps
    |> call("providers.set_primary", %{"provider" => provider}, @write_ms)
    |> emit(&Render.primary(&1, provider), flags, ctx, deps)
  end

  defp exec({:reload, flags}, deps) do
    ctx = context("fermix settings", :change, @write_ms, check: "fermix settings reload")

    deps
    |> call("settings.reload", %{}, @write_ms)
    |> emit(&Render.reload/1, flags, ctx, deps)
  end

  # The rows decide each literal's JSON type, and a secret row's key is refused
  # here before anything is applied: its value is never sent.
  defp set_flow(section, pairs, flags, deps) do
    ctx = context("fermix settings", :read, @read_ms, section: section)

    with {:ok, view} <- call(deps, "settings.get", %{"section" => section}, @read_ms),
         {:ok, rows} <- Render.rows(view),
         [] <- Args.secret_keys(pairs, rows) do
      apply_values(section, Args.values(pairs, rows), flags, deps)
    else
      [key | _more] -> secret_in_argv(:set, key, flags.json, deps)
      {:error, reason} -> refuse(reason, flags.json, ctx, deps)
    end
  end

  defp apply_values(section, values, flags, deps) do
    check = "fermix settings show #{section}"
    ctx = context("fermix settings", :change, @write_ms, section: section, check: check)

    deps
    |> call("settings.apply", %{"section" => section, "values" => values}, @write_ms)
    |> emit(&Render.applied(&1, section, Map.keys(values)), flags, ctx, deps)
  end

  # The preflight proves a daemon that speaks `settings.*` is reachable before
  # the operator types anything. The value lives only between the read and the
  # call, and no error term on either side carries it.
  defp secret_set_flow(id, flags, deps) do
    ctx = context("fermix settings secret set", :read, @read_ms)

    with {:ok, _sections} <- call(deps, "settings.sections", %{}, @read_ms),
         {:ok, value} <- read_secret(id, flags, deps) do
      store_secret(id, value, flags, deps)
    else
      {:error, reason} -> refuse(reason, flags.json, ctx, deps)
    end
  end

  defp store_secret(id, value, flags, deps) do
    ctx = context("fermix settings secret set", :secret_set, @secret_ms)

    deps
    |> call("secret.set", %{"id" => id, "value" => value}, @secret_ms)
    |> emit(&Render.secret(&1, :set), flags, ctx, deps)
  end

  defp read_secret(_id, %{stdin: true}, deps), do: SecretInput.read_stdin(deps.secret_input)
  defp read_secret(id, _flags, deps), do: SecretInput.read_masked(id, deps.secret_input)

  defp call(deps, method, params, timeout_ms),
    do: deps.client.(method, params, timeout: timeout_ms)

  # Every subcommand's output goes through here, so human vs `--json` and every
  # failure are handled once. A reply is validated by its renderer in both modes.
  defp emit({:ok, result}, renderer, flags, ctx, deps) do
    case renderer.(result) do
      {:ok, text} -> succeed(result, text, flags.json, deps)
      {:error, reason} -> refuse(reason, flags.json, ctx, deps)
    end
  end

  defp emit({:error, reason}, _renderer, flags, ctx, deps),
    do: refuse(reason, flags.json, ctx, deps)

  defp succeed(result, _text, true, deps) do
    IO.puts(deps.stdout, Render.json(result))
    0
  end

  defp succeed(_result, text, false, deps) do
    IO.write(deps.stdout, text)
    0
  end

  defp refuse(reason, json?, ctx, deps) do
    {status, sentence} = Render.error(reason, ctx)
    IO.puts(deps.stderr, [ctx.prefix, ": ", sentence])
    json_error(json?, reason, deps)
    status
  end

  defp usage(reason, json?, deps) do
    IO.write(deps.stderr, Render.usage(reason))
    json_error(json?, :usage, deps)
    2
  end

  defp secret_in_argv(form, key, json?, deps) do
    IO.write(deps.stderr, Render.secret_in_argv(form, key))
    json_error(json?, :secret_in_argv, deps)
    2
  end

  defp json_error(true, reason, deps),
    do: IO.puts(deps.stdout, Render.json(Render.error_json(reason)))

  defp json_error(false, _reason, _deps), do: :ok

  defp context(prefix, subject, timeout_ms, extra \\ []) do
    Map.merge(
      %{prefix: prefix, subject: subject, timeout_ms: timeout_ms, section: nil, check: nil},
      Map.new(extra)
    )
  end

  defp deps(opts) do
    %{
      client: Keyword.get(opts, :client, &Client.request_v1/3),
      stdout: Keyword.get(opts, :stdout, :stdio),
      stderr: Keyword.get(opts, :stderr, :stderr),
      secret_input: Keyword.get(opts, :secret_input, []),
      app_managed?: Keyword.get(opts, :app_managed?, &HomeOwner.app_managed?/0)
    }
  end
end
