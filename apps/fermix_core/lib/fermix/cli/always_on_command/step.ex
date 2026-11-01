defmodule Fermix.CLI.AlwaysOnCommand.Step do
  @moduledoc """
  One Always On step from the terminal (Always On setup §3.4, §8.2): for
  the action record pressed, collect what its `needs` lists, ask its
  `confirm`, and send one `home.act {action, key, input}` with the key it
  was drawn with. The engine runs the step; nothing here sequences calls.

  What a need takes:

    * `token`: the provider's token screen and a masked prompt on a
      terminal, else `--stdin`; the provider from `--provider`, the one
      `detail.providers` lists (left for Fermix to name), or a pick on a
      terminal.
    * `new_recovery_passphrase`: masked twice and compared, or
      `--recovery-passphrase-file`; `recovery_passphrase`: masked once, or
      the file. Either is sent as `input.recovery_passphrase`, and Fermix
      checks it.
    * `choice`: `--type` and `--location`; on a terminal, a numbered list of
      `home.provision.options` (the provider in use: the read names none,
      `options_request/0`) with the recommendation first; else Fermix's own
      recommendation.

  The input is held as `AlwaysOn.Input`, whose `Inspect` withholds the token
  and the passphrase, until the one call that sends it.

  Answers `{:acted, record, answer}`, `{:opened, record}` for a step the
  surface opens itself, `{:changed, sentence}`, `:declined`, `{:missing,
  flag}` (no terminal to ask on and no flag that gives it), or `{:refused,
  code, details}` with a `MachineOutput` code.
  """

  alias Fermix.CLI.AlwaysOnCommand
  alias Fermix.CLI.AlwaysOnCommand.Render
  alias Fermix.CLI.HomeCommand
  alias Fermix.CLI.SecretInput
  alias FermixCore.Management.AlwaysOn.Input

  @opened ~w(learn_more open_console update)
  # A token check takes up to about 45 s and a review sent to the server up
  # to 60 s, so every client allows `home.act` this long (PROTOCOL.md).
  @act_ms 90_000
  # Up to seven reads of the provider's catalog at 10 s each.
  @options_ms 90_000
  # A choice asked again at most this often before the step is left.
  @max_asks 3
  @token_flag "--stdin and pipe the token in"
  @passphrase_flag "--recovery-passphrase-file PATH"

  @type outcome ::
          {:acted, map(), map()}
          | {:opened, map()}
          | {:changed, String.t()}
          | :declined
          | {:missing, String.t()}
          | {:refused, atom(), keyword()}

  @doc "Takes the step `record` names, drawn on `summary`."
  @spec press(map(), map(), AlwaysOnCommand.context()) :: outcome()
  def press(%{"id" => id} = record, _summary, _ctx) when id in @opened, do: {:opened, record}

  def press(%{"needs" => needs} = record, summary, ctx) when is_list(needs) do
    with {:ok, input} <- collect(needs, summary, ctx),
         :ok <- confirm(record, ctx) do
      act(record, input, ctx)
    end
  end

  # ── needs ──────────────────────────────────────────────────────────────

  defp collect(needs, summary, ctx) do
    Enum.reduce_while(needs, {:ok, %Input{}}, fn need, {:ok, input} ->
      case need(need, input, summary, ctx) do
        {:ok, input} -> {:cont, {:ok, input}}
        other -> {:halt, other}
      end
    end)
  end

  defp need("token", input, summary, ctx) do
    providers = (summary["detail"] || %{})["providers"] || []

    with {:ok, provider, named} <- token_provider(providers, ctx),
         {:ok, token} <- token(provider, ctx) do
      {:ok, %{input | token: token, provider: named}}
    end
  end

  defp need("new_recovery_passphrase", input, _summary, ctx), do: passphrase(:twice, input, ctx)
  defp need("recovery_passphrase", input, _summary, ctx), do: passphrase(:once, input, ctx)
  defp need("choice", input, _summary, ctx), do: choice(input, ctx)

  defp need(need, _input, _summary, _ctx) do
    {:refused, :action_refused,
     output: "this step needs #{need}, which this fermix does not know; update it"}
  end

  # `provider` is named only when the owner named it or picked one: with one
  # provider offered, Fermix takes that one itself.
  defp token_provider(providers, ctx) do
    cond do
      ctx.flags.provider ->
        {:ok, Enum.find(providers, %{}, &(&1["id"] == ctx.flags.provider)), ctx.flags.provider}

      match?([_one], providers) ->
        {:ok, hd(providers), nil}

      ctx.interactive? and providers != [] ->
        pick_provider(providers, ctx)

      true ->
        {:missing, "--provider ID"}
    end
  end

  defp pick_provider(providers, ctx) do
    print(ctx.stdout, Render.provider_menu(providers))

    case ask(ctx, "Provider (Enter: #{hd(providers)["name"]}): ", length(providers)) do
      {:ok, :default} -> {:ok, hd(providers), hd(providers)["id"]}
      {:ok, n} -> {:ok, Enum.at(providers, n - 1), Enum.at(providers, n - 1)["id"]}
      :declined -> :declined
    end
  end

  defp token(provider, ctx) do
    cond do
      ctx.flags.stdin -> secret(SecretInput.read_stdin(ctx.secret), @token_flag)
      ctx.interactive? -> masked_token(provider, ctx)
      true -> {:missing, @token_flag}
    end
  end

  defp masked_token(provider, ctx) do
    print(ctx.stdout, Render.token_screen(provider))
    label = provider["token_label"] || "API token"
    secret(SecretInput.read_masked(label, ctx.secret), @token_flag)
  end

  defp passphrase(_times, input, %{flags: %{passphrase_file: path}}) when is_binary(path) do
    case HomeCommand.read_passphrase_file(Path.expand(path)) do
      {:ok, passphrase} ->
        {:ok, %{input | recovery_passphrase: passphrase}}

      {:error, reason} ->
        {:refused, :action_refused, output: HomeCommand.passphrase_sentence(reason)}
    end
  end

  defp passphrase(times, input, %{interactive?: true} = ctx) do
    case typed(times, ctx) do
      {:ok, passphrase} -> {:ok, %{input | recovery_passphrase: passphrase}}
      other -> other
    end
  end

  defp passphrase(_times, _input, _ctx), do: {:missing, @passphrase_flag}

  defp typed(:once, ctx),
    do: secret(SecretInput.read_masked("Recovery passphrase", ctx.secret), @passphrase_flag)

  defp typed(:twice, ctx) do
    with {:ok, first} <- masked("New recovery passphrase", ctx),
         {:ok, second} <- masked("Repeat it", ctx) do
      if first == second,
        do: {:ok, first},
        else: {:refused, :action_refused, output: "The two passphrases differ."}
    end
  end

  defp masked(label, ctx),
    do: secret(SecretInput.read_masked(label, ctx.secret), @passphrase_flag)

  # Nothing to read from is the flag's to give; any other failure says why,
  # never with the value.
  defp secret({:ok, value}, _flag), do: {:ok, value}

  defp secret({:error, reason}, flag) when reason in [:not_a_terminal, :no_input],
    do: {:missing, flag}

  defp secret({:error, :stdin_is_a_terminal}, _flag) do
    {:refused, :action_refused,
     output: "--stdin reads a pipe, and stdin is a terminal here: leave it out to be asked"}
  end

  defp secret({:error, reason}, _flag),
    do: {:refused, :action_refused, output: "the input could not be read (#{inspect(reason)})"}

  defp choice(input, %{flags: %{type: type, location: location}}) when is_binary(type),
    do: {:ok, %{input | type: type, location: location}}

  defp choice(input, %{interactive?: true} = ctx) do
    case options(ctx) do
      {:ok, options} -> choose(options, input, ctx)
      other -> other
    end
  end

  defp choice(input, _ctx), do: {:ok, input}

  @doc """
  The params of the `home.provision.options` read: none, since the engine
  answers for the provider in use (the one this home's token or server is
  with) and names it in its answer.
  """
  @spec options_request() :: map()
  def options_request, do: %{}

  defp options(ctx) do
    opts = AlwaysOnCommand.call_opts(ctx, @options_ms)

    case ctx.client.("home.provision.options", options_request(), opts) do
      {:ok, options} -> {:ok, options}
      {:error, :not_running} -> {:refused, :engine_stopped, []}
      {:error, reason} -> {:refused, :action_refused, output: AlwaysOnCommand.said(reason)}
    end
  end

  defp choose(%{"offers" => []} = options, _input, _ctx),
    do: {:refused, :action_refused, output: options["sentence"]}

  defp choose(options, input, ctx) do
    {lines, choices} = Render.offers(options)
    print(ctx.stdout, lines)

    case ask(ctx, "Size and place (Enter: 1): ", length(choices)) do
      {:ok, :default} -> chosen(hd(choices), input)
      {:ok, n} -> chosen(Enum.at(choices, n - 1), input)
      :declined -> :declined
    end
  end

  defp chosen(:recommended, input), do: {:ok, input}
  defp chosen({type, location}, input), do: {:ok, %{input | type: type, location: location}}

  # A number from 1 to `count`, or Enter for the default; asked again at
  # most @max_asks times, and EOF or `q` leaves the step.
  defp ask(ctx, prompt, count, asked \\ 1)
  defp ask(_ctx, _prompt, _count, asked) when asked > @max_asks, do: :declined

  defp ask(ctx, prompt, count, asked) do
    IO.write(ctx.stderr, prompt)

    case AlwaysOnCommand.answer(ctx) do
      "" -> {:ok, :default}
      "q" -> :declined
      text -> in_range(Integer.parse(text), count) || ask(ctx, prompt, count, asked + 1)
    end
  end

  defp in_range({n, ""}, count) when n >= 1 and n <= count, do: {:ok, n}
  defp in_range(_parsed, _count), do: nil

  # ── confirm and act ────────────────────────────────────────────────────

  defp confirm(%{"confirm" => nil}, _ctx), do: :ok
  defp confirm(_record, %{flags: %{yes: true}}), do: :ok

  defp confirm(%{"confirm" => confirm}, %{interactive?: true} = ctx) do
    IO.write(ctx.stderr, confirm <> " [y/N] ")
    if AlwaysOnCommand.answer(ctx) in ["y", "Y", "yes"], do: :ok, else: :declined
  end

  defp confirm(%{"confirm" => confirm}, _ctx), do: {:refused, :confirm_required, confirm: confirm}

  defp act(%{"id" => id, "key" => key} = record, input, ctx) do
    IO.puts(ctx.stderr, "fermix always-on: " <> id)
    params = put_input(%{"action" => id, "key" => key}, input)

    case ctx.client.("home.act", params, AlwaysOnCommand.call_opts(ctx, @act_ms)) do
      {:ok, %{"summary" => %{}} = answer} ->
        {:acted, record, answer}

      {:error, {:management_error, "changed", _message, details}} ->
        {:changed, details["sentence"]}

      {:error, :not_running} ->
        {:refused, :engine_stopped, []}

      {:error, reason} ->
        {:refused, :action_refused, output: AlwaysOnCommand.said(reason)}
    end
  end

  # The wire's input names only what was given; none at all sends no input.
  defp put_input(params, %Input{} = input) do
    wire =
      for {field, value} <- Map.from_struct(input),
          is_binary(value),
          into: %{},
          do: {Atom.to_string(field), value}

    if wire == %{}, do: params, else: Map.put(params, "input", wire)
  end

  defp print(device, lines), do: Enum.each(lines, &IO.puts(device, &1))
end
