defmodule Fermix.CLI.SecretInput do
  @moduledoc """
  Reads a credential from the operator without it ever entering argv.

  A secret passed as a command argument is readable in `ps`, in the shell's
  history file, and in any process-listing telemetry, so the CLI offers
  exactly two ways in — one interactive, one not:

    * `read_masked/2` — prompts on the terminal with echo disabled.
    * `read_stdin/1` — reads the secret from a pipe (`--stdin`).

  Each refuses the other's world instead of degrading: masked entry needs a
  terminal, `--stdin` needs a pipe. One fact decides both, whether stdin is a
  terminal, so the two can never both refuse the same stdin. Both strip a
  single trailing newline and nothing else, so a credential with meaningful
  surrounding characters survives; validating the value's shape belongs to the
  caller that knows which credential it is.

  `fermix setup` asks its secret questions among its other questions, on one
  stdin, so it reads them with `read_answer/2`: masked on a terminal, the next
  line of a pipe. A masked read ends by showing how many characters arrived,
  never what they were, because most secrets are pasted into a prompt that
  shows nothing.

  Deps are explicit. `:device` is the IO device the secret is read from
  (default `:standard_io`, which `IO` maps to the group leader, so
  `ExUnit.CaptureIO` drives it) and `:terminal` is the terminal-control
  implementation. The terminal also resolves from
  `:fermix_core, :secret_terminal`, so a CLI test can install a stub without
  every verb in between growing a pass-through argument.
  """

  # The prompt is a human notice, not output: it goes to stderr so a `--json`
  # verb's stdout stays parseable, the same rule the CLI's daemon notices use.
  @prompt_device :standard_error

  @type result :: {:ok, String.t()} | {:error, term()}

  @doc """
  Turns terminal echo on stdin on or off and answers whether it was on before,
  so the read restores exactly what it found.
  """
  @callback set_echo(boolean()) :: {:ok, boolean()} | {:error, term()}

  @doc "Whether stdin is a terminal rather than a pipe or a file."
  @callback stdin_terminal?() :: boolean()

  @doc """
  Prompts `label` on the terminal and reads one line with echo disabled.

  Fails with `{:error, :not_a_terminal}` when stdin is not a terminal, rather
  than reading an unmasked line from whatever else is attached.
  """
  @spec read_masked(String.t(), keyword()) :: result()
  def read_masked(label, opts \\ []) when is_binary(label) and is_list(opts) do
    device = Keyword.get(opts, :device, :standard_io)
    terminal = terminal(opts)

    if terminal.stdin_terminal?() do
      read_unechoed(device, terminal, label)
    else
      {:error, :not_a_terminal}
    end
  end

  @doc """
  Reads the answer to one `fermix setup` question that asks for a secret.

  Setup reads its answers a line at a time from whatever stdin is: on a
  terminal the answer is read as `read_masked/2` reads it, and from a pipe it
  is the next line, which nothing echoes, so a script that pipes its answers in
  keeps every later answer for the questions after this one.
  """
  @spec read_answer(String.t(), keyword()) :: result()
  def read_answer(label, opts \\ []) when is_binary(label) and is_list(opts) do
    device = Keyword.get(opts, :device, :standard_io)
    terminal = terminal(opts)

    if terminal.stdin_terminal?() do
      read_unechoed(device, terminal, label)
    else
      device |> IO.gets("#{label}: ") |> input()
    end
  end

  @doc """
  Whether stdin is a terminal, by the same terminal the reads use: a verb
  that prompts only on a terminal asks this, so it never decides otherwise
  than `read_masked/2` and `read_stdin/1` will.
  """
  @spec terminal?(keyword()) :: boolean()
  def terminal?(opts \\ []) when is_list(opts), do: terminal(opts).stdin_terminal?()

  @doc """
  Reads the secret from stdin, for `--stdin` and any non-interactive caller.

  Fails with `{:error, :stdin_is_a_terminal}` rather than hanging on a
  terminal that will never send EOF.
  """
  @spec read_stdin(keyword()) :: result()
  def read_stdin(opts \\ []) when is_list(opts) do
    device = Keyword.get(opts, :device, :standard_io)

    if terminal(opts).stdin_terminal?() do
      {:error, :stdin_is_a_terminal}
    else
      device |> IO.read(:eof) |> input()
    end
  end

  # Echo is restored on every exit path — an error tuple, an `:eof`, a raise
  # from the device — because a CLI that dies with echo off leaves the
  # operator's shell silently swallowing keystrokes.
  defp read_unechoed(device, terminal, label) do
    case terminal.set_echo(false) do
      {:ok, echo_before?} ->
        try do
          IO.write(@prompt_device, "#{label}: ")
          result = device |> IO.gets("") |> input()
          IO.write(@prompt_device, received(result))
          result
        after
          restore_echo(terminal, echo_before?)
        end

      {:error, reason} ->
        {:error, {:terminal_setup_failed, reason}}
    end
  end

  # Most secrets are pasted into a prompt that shows nothing, so the length is
  # the operator's one sign the paste landed. It says how much arrived, never
  # what; an empty line shows no count.
  defp received({:ok, ""}), do: ""
  defp received({:ok, value}), do: "(#{characters(String.length(value))})"
  defp received({:error, _reason}), do: ""

  defp characters(1), do: "1 character"
  defp characters(count), do: "#{count} characters"

  # The newline closes the line the operator typed into but never saw.
  defp restore_echo(terminal, echo_before?) do
    IO.write(@prompt_device, "\n")

    case terminal.set_echo(echo_before?) do
      {:ok, _echo} ->
        :ok

      {:error, reason} ->
        IO.puts(
          @prompt_device,
          "fermix: terminal echo could not be restored (#{inspect(reason)}) — run `stty echo`"
        )
    end
  end

  defp input(:eof), do: {:error, :no_input}
  defp input({:error, reason}), do: {:error, {:read_failed, reason}}
  defp input(value) when is_binary(value), do: {:ok, strip_newline(value)}
  # Never put the value in an error term — it is the secret.
  defp input(_other), do: {:error, :unexpected_input_encoding}

  defp strip_newline(value) do
    value |> String.replace_suffix("\n", "") |> String.replace_suffix("\r", "")
  end

  defp terminal(opts) do
    Keyword.get(opts, :terminal) ||
      Application.get_env(:fermix_core, :secret_terminal, __MODULE__.Terminal)
  end
end

defmodule Fermix.CLI.SecretInput.Terminal do
  @moduledoc """
  The real terminal: stdin's terminal fact from OTP's io server, and the
  kernel terminal driver's echo flag through `FermixNif`.

  A shipped `fermix` runs under `-noshell` on an ERTS built without termcap,
  so the tty stays in cooked mode and the kernel, not the VM, echoes and
  assembles the line. That makes the kernel's ECHO flag the one switch that
  hides input there, and it is the same switch on a VM that has termcap.
  OTP's own no-echo mode (`shell:start_interactive({noshell, raw})` and
  `io:get_password/0`) needs termcap, so on a shipped binary it answers
  `{:error, :enotsup}` on every terminal; it is not used.
  """

  @behaviour Fermix.CLI.SecretInput

  @impl true
  def set_echo(echo?) when is_boolean(echo?), do: FermixNif.set_stdin_echo(echo?)

  # `stdin` (not `terminal`) is the field that answers the question asked:
  # with stdout on a tty and stdin redirected from a file, `terminal` is still
  # true while `stdin` is false, and it is stdin the reads depend on.
  @impl true
  def stdin_terminal? do
    :standard_io |> :io.getopts() |> Keyword.get(:stdin, false)
  end
end
