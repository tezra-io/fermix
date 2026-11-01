defmodule Fermix.CLI.AlwaysOnCommand do
  @moduledoc """
  `fermix always-on` (Always On setup §8.2): Always On from a terminal, for
  a Homebrew or Linux install without the Fermix app.

      fermix always-on [--json]
      fermix always-on ACTION [--provider ID] [--type T --location L] [--stdin]
                       [--recovery-passphrase-file PATH] [--yes] [--wait] [--json]

  The engine owns the flow. The verb reads `home.status` and draws its
  summary; for the step asked (`ACTION`, an action id in kebab form) it
  collects what the action `needs`, asks its `confirm`, sends one
  `home.act {action, key, input}` with the key the action was drawn with,
  and draws the answer. It never sequences calls, follows a job, picks a
  server or words what the engine words (`AlwaysOnCommand.Step`).

  **On a terminal** (and without `--json`), `fermix always-on` with no
  step prints the screen and its steps numbered, Enter taking the main one
  and `q` quitting; it asks what the step needs (the token masked, the
  recovery passphrase masked, twice where none is set, the size and place
  as a numbered list with the recommendation first), shows the confirm as
  `[y/N]`, acts, waits for the screen to move on (`AlwaysOnCommand.Wait`)
  and offers the next step, until the owner quits. A step on its own waits
  too.

  **Without a terminal, or with `--json`,** it never prompts: a step that
  needs what no flag gave is a usage error naming the flag (exit 2); a
  confirm without `--yes` is `confirm_required` (exit 1); Always On changed
  since the screen was read is `changed` (exit 1, with the screen read
  again under `--json`); any other refusal is `action_refused` with the
  engine's sentence. It waits only with `--wait`.

  Secrets never enter argv: the token comes from the masked prompt or
  `--stdin`, the recovery passphrase from the masked prompt or
  `--recovery-passphrase-file`, and either typed as an argument is refused
  by name. Prompts, the step's id as it runs and the wait's lines go to
  stderr; the screen, or the one `--json` envelope, to stdout.

  On a home the Fermix app manages (`HomeOwner.app_managed?/1`, given this
  verb's own `hello`) it refuses `app_managed`, naming the app's Always On
  pane. With Fermix stopped it refuses `engine_stopped` and writes nothing.

  Exit status: `0` done, `1` refused, `2` usage error.

  Dependencies: `:home`, `:client` (a 3-arity management call, as
  `Client.request_v1/3`), `:terminal` (the `SecretInput` terminal), `:stdin`,
  `:stdout`, `:stderr`, `:app_managed?` (as `HomeOwner.app_managed?/1`),
  `:now_ms` (a 0-arity monotonic clock) and `:sleep`.
  """

  alias Fermix.CLI.AlwaysOnCommand.Render
  alias Fermix.CLI.AlwaysOnCommand.Step
  alias Fermix.CLI.AlwaysOnCommand.Wait
  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.HomeOwner
  alias Fermix.CLI.MachineOutput
  alias Fermix.CLI.SecretInput
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.EngineOwner

  @switches [
    provider: :string,
    type: :string,
    location: :string,
    stdin: :boolean,
    recovery_passphrase_file: :string,
    yes: :boolean,
    wait: :boolean,
    json: :boolean
  ]
  @secret_flags ~w(--token --recovery-passphrase)
  @hello_ms 10_000
  @status_ms 30_000
  # The guided loop's bound: a session that takes this many steps stops and
  # says so; running the verb again goes on from where Always On stands.
  @max_rounds 100
  @usage """
  Usage:
    fermix always-on [--json]
    fermix always-on ACTION [--provider ID] [--type T --location L] [--stdin]
                     [--recovery-passphrase-file PATH] [--yes] [--wait] [--json]

  ACTION is one of the steps Always On offers now:
    paste-token create-server cancel move-now try-again turn-on restart-server
    start-again create-in back-up-now replace-server check-again own-server
    delete-server learn-more open-console update
  """

  @type context :: map()

  @doc "Runs `fermix always-on ARGS` with the dependencies the moduledoc names."
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps \\ []) when is_list(argv) and is_list(deps) do
    case parse(argv) do
      {:ok, step, flags} -> deps |> context(flags) |> start(step)
      {:usage, sentence} -> usage(sentence, deps)
    end
  end

  @doc "Every step the verb takes, in the kebab form `ACTION` names it."
  @spec steps() :: [String.t()]
  def steps, do: Enum.map(HomeSummary.actions(), &Render.kebab/1)

  @doc "A step's `--json` result: the screen after it and what the step answered."
  @spec step_result(map(), map() | nil) :: map()
  def step_result(summary, result) when is_map(summary),
    do: %{"summary" => summary, "result" => result}

  # ── arguments ──────────────────────────────────────────────────────────

  defp parse(argv) do
    case Enum.find(argv, &secret_flag?/1) do
      nil -> parse_flags(argv)
      _flag -> {:usage, secret_sentence()}
    end
  end

  defp secret_flag?(arg),
    do: arg in @secret_flags or String.starts_with?(arg, Enum.map(@secret_flags, &(&1 <> "=")))

  defp secret_sentence do
    "fermix always-on: a token or a passphrase is never taken as an argument, where shell " <>
      "history and process lists keep it. Pipe the token in with --stdin, pass " <>
      "--recovery-passphrase-file PATH, or run on a terminal to be asked."
  end

  defp parse_flags(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} -> no_step(flags(opts))
      {opts, [step], []} -> one_step(step, flags(opts))
      _invalid -> {:usage, nil}
    end
  end

  # With no step the verb draws the screen: `--json` is its one flag.
  defp no_step(flags) do
    if flags == flags(json: flags.json), do: {:ok, nil, flags}, else: {:usage, nil}
  end

  defp one_step(step, flags) do
    cond do
      step not in steps() -> {:usage, nil}
      is_nil(flags.type) != is_nil(flags.location) -> {:usage, nil}
      true -> {:ok, step, flags}
    end
  end

  defp flags(opts) do
    %{
      provider: Keyword.get(opts, :provider),
      type: Keyword.get(opts, :type),
      location: Keyword.get(opts, :location),
      stdin: Keyword.get(opts, :stdin, false),
      passphrase_file: Keyword.get(opts, :recovery_passphrase_file),
      yes: Keyword.get(opts, :yes, false),
      wait: Keyword.get(opts, :wait, false),
      json: Keyword.get(opts, :json, false)
    }
  end

  defp context(deps, flags) do
    home = Path.expand(Keyword.get_lazy(deps, :home, &ConfigStore.fermix_home/0))
    stdin = Keyword.get(deps, :stdin, :stdio)
    secret = [terminal: Keyword.get(deps, :terminal), device: stdin]

    %{
      flags: flags,
      home: home,
      client: Keyword.get(deps, :client, &Client.request_v1/3),
      socket: Path.join(home, "daemon.sock"),
      stdin: stdin,
      stdout: Keyword.get(deps, :stdout, :stdio),
      stderr: Keyword.get(deps, :stderr, :stderr),
      secret: Enum.reject(secret, &is_nil(elem(&1, 1))),
      interactive?: SecretInput.terminal?(Keyword.take(deps, [:terminal])) and not flags.json,
      app_managed?: Keyword.get(deps, :app_managed?, &HomeOwner.app_managed?/1),
      now_ms: Keyword.get(deps, :now_ms, fn -> System.monotonic_time(:millisecond) end),
      sleep: Keyword.get(deps, :sleep, &Process.sleep/1)
    }
  end

  # ── the engine, before any step ────────────────────────────────────────

  defp start(ctx, step) do
    with {:ok, hello} <- hello(ctx),
         :ok <- not_app_managed(hello, ctx),
         {:ok, status} <- read_status(ctx) do
      take(step, status["summary"], ctx)
    else
      {:refused, code, details} -> refuse(code, details, ctx)
    end
  end

  # The verb's own `hello` decides who manages the home, so the home-owner
  # check asks the daemon nothing a second time; with no daemon, the marker
  # in this home decides.
  defp hello(ctx) do
    case ctx.client.("hello", %{}, call_opts(ctx, @hello_ms)) do
      {:ok, hello} -> {:ok, {:ok, hello}}
      {:error, :not_running} -> stopped(ctx)
      {:error, reason} -> {:refused, :home_status_unavailable, output: said(reason)}
    end
  end

  defp stopped(ctx) do
    if app_managed?({:error, :not_running}, ctx),
      do: {:refused, :app_managed, surface: :always_on},
      else: {:refused, :engine_stopped, []}
  end

  defp not_app_managed(hello, ctx) do
    if app_managed?(hello, ctx), do: {:refused, :app_managed, surface: :always_on}, else: :ok
  end

  defp app_managed?(hello, ctx) do
    marker = Path.join(ctx.home, Path.basename(EngineOwner.path()))
    ctx.app_managed?.(hello: fn -> hello end, path: marker)
  end

  @doc false
  @spec read_status(context()) :: {:ok, map()} | {:refused, atom(), keyword()}
  def read_status(ctx) do
    case ctx.client.("home.status", %{}, call_opts(ctx, @status_ms)) do
      {:ok, %{"summary" => %{} = _summary} = status} -> {:ok, status}
      {:ok, _no_summary} -> {:refused, :home_status_unavailable, output: older_sentence()}
      {:error, :not_running} -> {:refused, :engine_stopped, []}
      {:error, reason} -> {:refused, :home_status_unavailable, output: said(reason)}
    end
  end

  defp older_sentence, do: "this Fermix is older than Always On's screen; update it"

  # ── modes ──────────────────────────────────────────────────────────────

  defp take(nil, summary, %{interactive?: true} = ctx), do: guided(summary, :screen, ctx, 0)

  defp take(nil, summary, ctx) do
    if ctx.flags.json,
      do: IO.puts(ctx.stdout, MachineOutput.ok(summary)),
      else: print(ctx.stdout, Render.screen(summary) ++ Render.steps(summary))

    0
  end

  defp take(step, summary, ctx) do
    id = String.replace(step, "-", "_")

    case Enum.find(Render.records(summary), &(&1["id"] == id)) do
      nil -> refuse(:action_refused, [not_offered: step], ctx)
      record -> record |> Step.press(summary, ctx) |> finish(summary, ctx)
    end
  end

  # One step on its own: what it answered, then the screen it leaves.
  defp finish({:acted, record, answer}, _summary, ctx) do
    unless ctx.flags.json, do: print(ctx.stdout, Render.result(answer["result"]))

    case follow(answer["summary"], record, ctx, ctx.flags.wait or ctx.interactive?) do
      {:ok, summary} -> done(step_result(summary, answer["result"]), ctx)
      {:refused, code, details} -> refuse(code, details, ctx)
    end
  end

  defp finish({:opened, record}, summary, ctx) do
    if ctx.flags.json,
      do: IO.puts(ctx.stdout, MachineOutput.ok(step_result(summary, %{"url" => record["url"]}))),
      else: IO.puts(ctx.stdout, Render.opened(record))

    0
  end

  defp finish({:changed, sentence}, _summary, ctx) do
    case read_status(ctx) do
      {:ok, status} -> changed(sentence, status["summary"], ctx)
      {:refused, _code, _details} -> refuse(:changed, [reason: sentence], ctx)
    end
  end

  defp finish(:declined, _summary, ctx) do
    IO.puts(ctx.stderr, "fermix always-on: nothing was done.")
    1
  end

  defp finish({:missing, flag}, _summary, ctx) do
    why =
      if ctx.interactive?, do: "", else: "nothing is asked without a terminal or with --json, so "

    IO.puts(ctx.stderr, "fermix always-on: #{why}pass #{flag}.")
    2
  end

  defp finish({:refused, code, details}, _summary, ctx), do: refuse(code, details, ctx)

  defp changed(sentence, summary, ctx) do
    status = refuse(:changed, [reason: sentence], ctx, %{"summary" => summary})
    unless ctx.flags.json, do: print(ctx.stdout, Render.screen(summary))
    status
  end

  defp follow(summary, _record, _ctx, false), do: {:ok, summary}

  defp follow(summary, record, ctx, true),
    do: summary |> Wait.follow(pressed(record), ctx) |> settled(ctx)

  # A step that moves the home restarts this engine; every other leaves it.
  defp pressed(%{"id" => id}) when id in ~w(move_now try_again), do: :move
  defp pressed(_record), do: :step

  defp settled({:bounded, summary}, ctx) do
    IO.puts(
      ctx.stderr,
      "Always On is still at it after 45 minutes; fermix always-on shows where it stands."
    )

    {:ok, summary}
  end

  defp settled(other, _ctx), do: other

  defp done(answer, ctx) do
    if ctx.flags.json,
      do: IO.puts(ctx.stdout, MachineOutput.ok(answer)),
      else: print(ctx.stdout, Render.screen(answer["summary"]))

    0
  end

  # ── the guided loop, on a terminal ─────────────────────────────────────

  defp guided(_summary, _since, ctx, round) when round >= @max_rounds do
    IO.puts(ctx.stderr, "fermix always-on: that is #{@max_rounds} steps; run it again to go on.")
    0
  end

  defp guided(summary, since, ctx, round) do
    case summary |> Wait.follow(since, ctx) |> settled(ctx) do
      {:ok, summary} -> offer(summary, ctx, round)
      {:refused, code, details} -> refuse(code, details, ctx)
    end
  end

  defp offer(summary, ctx, round) do
    records = Render.records(summary)
    print(ctx.stdout, Render.screen(summary) ++ Render.menu(records))

    case pick(summary, records, ctx) do
      :quit -> 0
      record -> record |> Step.press(summary, ctx) |> next(summary, ctx, round + 1)
    end
  end

  defp pick(_summary, [], _ctx), do: :quit

  defp pick(summary, records, ctx) do
    IO.write(ctx.stderr, Render.menu_prompt(summary))

    case answer(ctx) do
      "" -> summary["action"] || :quit
      "q" -> :quit
      text -> numbered(text, records) || :quit
    end
  end

  defp numbered(text, records) do
    case Integer.parse(text) do
      {n, ""} when n >= 1 -> Enum.at(records, n - 1)
      _other -> nil
    end
  end

  defp next({:acted, record, answer}, _summary, ctx, round) do
    print(ctx.stdout, Render.result(answer["result"]))
    guided(answer["summary"], pressed(record), ctx, round)
  end

  defp next({:opened, record}, summary, ctx, round) do
    IO.puts(ctx.stdout, Render.opened(record))
    guided(summary, :screen, ctx, round)
  end

  defp next(:declined, summary, ctx, round) do
    IO.puts(ctx.stderr, "fermix always-on: nothing was done.")
    guided(summary, :screen, ctx, round)
  end

  defp next({:changed, sentence}, _summary, ctx, round) do
    IO.puts(ctx.stderr, "fermix always-on: " <> sentence)
    read_again(ctx, round)
  end

  defp next({:missing, flag}, summary, ctx, round) do
    IO.puts(ctx.stderr, "fermix always-on: this step needs #{flag} here.")
    guided(summary, :screen, ctx, round)
  end

  defp next({:refused, code, details}, _summary, ctx, round) when code != :engine_stopped do
    IO.puts(ctx.stderr, "fermix always-on: " <> MachineOutput.sentence(code, details))
    read_again(ctx, round)
  end

  defp next({:refused, code, details}, _summary, ctx, _round), do: refuse(code, details, ctx)

  defp read_again(ctx, round) do
    case read_status(ctx) do
      {:ok, status} -> guided(status["summary"], :screen, ctx, round)
      {:refused, code, details} -> refuse(code, details, ctx)
    end
  end

  # ── output ─────────────────────────────────────────────────────────────

  @doc false
  @spec answer(context()) :: String.t()
  def answer(ctx) do
    case IO.gets(ctx.stdin, "") do
      line when is_binary(line) -> String.trim(line)
      _eof_or_error -> "q"
    end
  end

  @doc false
  @spec call_opts(context(), pos_integer()) :: keyword()
  def call_opts(ctx, timeout_ms), do: [socket_path: ctx.socket, timeout: timeout_ms]

  @doc false
  @spec said(term()) :: String.t()
  def said({:management_error, _code, _message, %{"sentence" => sentence}})
      when is_binary(sentence),
      do: sentence

  def said({:management_error, _code, message, _details}) when is_binary(message), do: message
  def said(reason), do: Client.describe_error(reason)

  # A refusal says its sentence on stderr in both modes, and under `--json`
  # prints its envelope on stdout too, so a script reads the code and a
  # person the words.
  defp refuse(code, details, ctx, extra \\ %{}) do
    IO.puts(ctx.stderr, "fermix always-on: " <> MachineOutput.sentence(code, details))
    if ctx.flags.json, do: IO.puts(ctx.stdout, MachineOutput.error(code, details, extra))
    1
  end

  defp print(device, lines), do: Enum.each(lines, &IO.puts(device, &1))

  defp usage(sentence, deps) do
    stderr = Keyword.get(deps, :stderr, :stderr)
    if sentence, do: IO.puts(stderr, sentence)
    IO.write(stderr, @usage)
    2
  end
end
