defmodule FermixTestSupport.TtyTerminal do
  @moduledoc """
  The interactive world: stdin is a terminal, so raw mode is available and
  `--stdin` must refuse. Echo changes are reported to the calling process (the
  CLI runs inline in the test process) so a test can pin that entry was
  unechoed and that echo was restored, without any global state.
  """

  @behaviour Fermix.CLI.SecretInput

  @impl true
  def enter_raw, do: :ok

  @impl true
  def set_echo(echo?) when is_boolean(echo?) do
    send(self(), {:secret_input_echo, echo?})
    :ok
  end

  @impl true
  def stdin_terminal?, do: true
end

defmodule FermixTestSupport.PipedTerminal do
  @moduledoc """
  The non-interactive world: stdin is a pipe or a file, so `--stdin` works and
  masked entry must refuse with the same `:enotsup` OTP reports for a
  non-terminal stdin.
  """

  @behaviour Fermix.CLI.SecretInput

  @impl true
  def enter_raw, do: {:error, :enotsup}

  @impl true
  def set_echo(echo?) when is_boolean(echo?), do: {:error, :enotsup}

  @impl true
  def stdin_terminal?, do: false
end
