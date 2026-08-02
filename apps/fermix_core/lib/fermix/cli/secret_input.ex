defmodule Fermix.CLI.SecretInput do
  @moduledoc """
  Reads a credential from the operator without it ever entering argv.

  A secret passed as a command argument is readable in `ps`, in the shell's
  history file, and in any process-listing telemetry, so the CLI offers
  exactly two ways in — one interactive, one not:

    * `read_masked/2` — prompts on the terminal with echo disabled.
    * `read_stdin/1` — reads the secret from a pipe (`--stdin`).

  Each refuses the other's world instead of degrading: masked entry needs a
  terminal, `--stdin` needs a pipe. Both strip a single trailing newline and
  nothing else, so a credential with meaningful surrounding characters
  survives; validating the value's shape belongs to the caller that knows
  which credential it is.

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
  Hands the terminal to the VM so it, rather than the kernel tty driver,
  owns echoing. Answers `{:error, :enotsup}` when stdin is not a terminal.
  """
  @callback enter_raw() :: :ok | {:error, term()}

  @doc "Turns terminal echo on or off."
  @callback set_echo(boolean()) :: :ok | {:error, term()}

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

    with :ok <- enter_interactive(terminal) do
      read_unechoed(device, terminal, label)
    end
  end

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
    with :ok <- terminal.set_echo(false) do
      try do
        IO.write(@prompt_device, "#{label}: ")
        device |> IO.gets("") |> input()
      after
        restore_echo(terminal)
      end
    end
  end

  # The newline closes the line the operator typed into but never saw.
  defp restore_echo(terminal) do
    IO.write(@prompt_device, "\n")

    case terminal.set_echo(true) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(
          @prompt_device,
          "fermix: terminal echo could not be restored (#{inspect(reason)}) — run `stty echo`"
        )
    end
  end

  defp enter_interactive(terminal) do
    case terminal.enter_raw() do
      :ok -> :ok
      {:error, :enotsup} -> {:error, :not_a_terminal}
      {:error, reason} -> {:error, {:terminal_setup_failed, reason}}
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
  The real terminal, driven through OTP's io server.

  `enter_raw/0` is both the setup step and the gate. A shipped `fermix` runs
  under `-noshell`, where the tty stays in cooked mode: the kernel — not the
  VM — echoes, so `:io.setopts(echo: false)` returns `:ok` and changes
  nothing. `:shell.start_interactive({:noshell, :raw})` hands the terminal to
  the VM's line editor, which does honour the echo option, and it answers
  `{:error, :enotsup}` when stdin is not a terminal — so the gate probes
  exactly the capability the masked read depends on. It is idempotent and
  one-way: raw mode lasts for the rest of the OS process, which for a CLI
  verb is the handful of lines it still prints (the VM keeps translating
  `\\n` for them).
  """

  @behaviour Fermix.CLI.SecretInput

  @impl true
  def enter_raw, do: :shell.start_interactive({:noshell, :raw})

  @impl true
  def set_echo(echo?) when is_boolean(echo?), do: :io.setopts(:standard_io, echo: echo?)

  # `stdin` (not `terminal`) is the field that answers the question asked:
  # with stdout on a tty and stdin redirected from a file, `terminal` is still
  # true while `stdin` is false, and it is stdin the reads depend on.
  @impl true
  def stdin_terminal? do
    :standard_io |> :io.getopts() |> Keyword.get(:stdin, false)
  end
end
