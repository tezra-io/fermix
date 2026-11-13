defmodule Fermix.CLI.AlwaysOnCommand.Step do
  @moduledoc """
  One Always On step from the terminal (Always On setup §3.4, §8.2): for
  the action record pressed, collect what its `needs` lists, ask its
  `confirm`, and send one `home.act {action, key, input}` with the key it
  was drawn with. The engine runs the step; nothing here sequences calls.

  What a need takes: `new_recovery_passphrase` (the first Move now's, and
  the backup settings' Change, `change_passphrase`), masked twice and
  compared, or `--recovery-passphrase-file`; `recovery_passphrase`, masked once, or
  the file. Either is sent as `input.recovery_passphrase`, and Fermix checks
  it. `sas` (M97 §7.5) is the six digits the computer that asks to join
  shows, read from `--sas` or asked on the terminal, sent as `input.sas`.

  The input is held as `AlwaysOn.Input`, whose `Inspect` withholds the
  passphrase, until the one call that sends it.

  Answers `{:acted, record, answer}`, `{:opened, record}` for the step the
  surface opens itself (`update`), `{:changed, sentence}`, `{:unconfirmed, record,
  sentence}` (a linked desktop's Move now the server had but whose answer
  was lost: the move may have started, so it is followed as a started one),
  `:declined`, `{:missing, flag}` (no terminal to ask on and no flag that
  gives it), or `{:refused, code, details}` with a `MachineOutput` code.
  """

  alias Fermix.CLI.AlwaysOnCommand
  alias Fermix.CLI.HomeCommand
  alias Fermix.CLI.SecretInput
  alias FermixCore.Management.AlwaysOn.Input

  @opened ~w(update)
  # A review sent to the server takes up to 60 s, so every client allows
  # `home.act` this long (PROTOCOL.md).
  @act_ms 90_000
  @passphrase_flag "--recovery-passphrase-file PATH"
  @sas_flag "--sas DIGITS"

  @type outcome ::
          {:acted, map(), map()}
          | {:opened, map()}
          | {:changed, String.t()}
          | {:unconfirmed, map(), String.t()}
          | :declined
          | {:missing, String.t()}
          | {:refused, atom(), keyword()}

  @doc "Takes the step `record` names, drawn on `summary`."
  @spec press(map(), map(), AlwaysOnCommand.context()) :: outcome()
  def press(%{"id" => id} = record, _summary, _ctx) when id in @opened, do: {:opened, record}

  def press(%{"needs" => needs} = record, _summary, ctx) when is_list(needs) do
    with {:ok, input} <- collect(needs, ctx),
         :ok <- confirm(record, ctx) do
      act(record, input, ctx)
    end
  end

  # ── needs ──────────────────────────────────────────────────────────────

  defp collect(needs, ctx) do
    Enum.reduce_while(needs, {:ok, %Input{}}, fn need, {:ok, input} ->
      case need(need, input, ctx) do
        {:ok, input} -> {:cont, {:ok, input}}
        other -> {:halt, other}
      end
    end)
  end

  defp need("new_recovery_passphrase", input, ctx), do: passphrase(:twice, input, ctx)
  defp need("recovery_passphrase", input, ctx), do: passphrase(:once, input, ctx)
  defp need("sas", input, ctx), do: digits(input, ctx)

  defp need(need, _input, _ctx) do
    {:refused, :action_refused,
     output: "this step needs #{need}, which this fermix does not know; update it"}
  end

  # The digits are no secret: the new computer shows them, and the owner
  # types what they read there.
  defp digits(input, %{flags: %{sas: sas}}) when is_binary(sas), do: {:ok, %{input | sas: sas}}

  defp digits(input, %{interactive?: true} = ctx) do
    IO.write(ctx.stderr, "The six digits the new computer shows: ")
    {:ok, %{input | sas: AlwaysOnCommand.answer(ctx)}}
  end

  defp digits(_input, _ctx), do: {:missing, @sas_flag}

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

  defp secret({:error, reason}, _flag),
    do: {:refused, :action_refused, output: "the input could not be read (#{inspect(reason)})"}

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

      {:error, {:management_error, "unconfirmed", _message, _details} = reason} ->
        {:unconfirmed, record, AlwaysOnCommand.said(reason)}

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
end
