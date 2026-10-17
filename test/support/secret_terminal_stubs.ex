defmodule FermixTestSupport.TtyTerminal do
  @moduledoc """
  The interactive world: stdin is a terminal, so masked entry reads and
  `--stdin` must refuse. Echo starts on. Echo changes are reported to the
  calling process (the CLI runs inline in the test process) so a test can pin
  that entry was unechoed and that echo was restored, without any global state.
  """

  @behaviour Fermix.CLI.SecretInput

  @impl true
  def set_echo(echo?) when is_boolean(echo?) do
    send(self(), {:secret_input_echo, echo?})
    {:ok, true}
  end

  @impl true
  def stdin_terminal?, do: true
end

defmodule FermixTestSupport.PipedTerminal do
  @moduledoc """
  The non-interactive world: stdin is a pipe or a file, so `--stdin` works and
  masked entry must refuse. The echo switch answers what the terminal driver
  answers for a descriptor that is not a terminal; masked entry must refuse
  before it ever asks.
  """

  @behaviour Fermix.CLI.SecretInput

  @impl true
  def set_echo(echo?) when is_boolean(echo?) do
    send(self(), {:secret_input_echo, echo?})
    {:error, :enotty}
  end

  @impl true
  def stdin_terminal?, do: false
end
