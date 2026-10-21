defmodule Fermix.CLI.SecretInputTest do
  # Sync because `:standard_error` is one globally registered device and
  # `ExUnit.CaptureIO` captures it by name: concurrent captures share a single
  # buffer, so a capturer sees everything any other async test wrote during the
  # overlap. Every assertion below pins the prompt exactly ("nothing was
  # prompted", "the prompt does not contain the secret"), which a foreign line
  # breaks. Having the writers capture their own stderr does not help — the
  # sharing is between capturers. Sync runs after every async module, so no
  # other test's stderr can overlap.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.SecretInput
  alias FermixTestSupport.PipedTerminal
  alias FermixTestSupport.TtyTerminal

  describe "read_masked/2" do
    test "prompts on stderr, reads one line, and never echoes it" do
      result = with_masked_input("topsecret\n", terminal: TtyTerminal)

      assert result.value == {:ok, "topsecret"}
      assert result.prompt == "Paste a token: (9 characters)\n"
      refute result.prompt =~ "topsecret"
      # The prompt is a notice, so a `--json` verb's stdout stays parseable.
      assert result.output == ""
    end

    # Most secrets are pasted into a prompt that shows nothing, so the count is
    # the operator's one sign the paste landed.
    test "an empty line shows no count, so a paste that missed is visible" do
      result = with_masked_input("\n", terminal: TtyTerminal)

      assert result.value == {:ok, ""}
      assert result.prompt == "Paste a token: \n"
    end

    test "disables echo for the read and restores it afterwards" do
      with_masked_input("topsecret\n", terminal: TtyTerminal)

      assert_received {:secret_input_echo, false}
      assert_received {:secret_input_echo, true}
    end

    test "restores echo even when the read yields nothing" do
      result = with_masked_input("", terminal: TtyTerminal)

      assert result.value == {:error, :no_input}
      assert_received {:secret_input_echo, false}
      assert_received {:secret_input_echo, true}
    end

    test "refuses when stdin is not a terminal instead of reading it unmasked" do
      result = with_masked_input("topsecret\n", terminal: PipedTerminal)

      assert result.value == {:error, :not_a_terminal}
      # Nothing was prompted, nothing was consumed, and the echo switch was
      # never asked: the stdin fact alone refused.
      assert result.prompt == ""
      assert result.output == ""
      refute_received {:secret_input_echo, _echo}
    end

    # The 0.15.0 split: stdin was a terminal (so `--stdin` refused) while the
    # VM's own no-echo mode was unavailable (so masked entry refused too). The
    # stub is that world: its stdin is a terminal and its VM refuses raw mode.
    # Masked entry asks the same stdin fact `--stdin` asks, so it reads.
    test "on a terminal whose VM has no raw mode, masked entry reads and --stdin refuses" do
      terminal = __MODULE__.NoRawModeTerminal

      assert with_masked_input("topsecret\n", terminal: terminal).value == {:ok, "topsecret"}

      assert capture_read_stdin("topsecret\n", terminal: terminal) ==
               {:error, :stdin_is_a_terminal}

      assert_received {:secret_input_echo, false}
    end

    # One fact, two readers: whatever stdin is, exactly one of them reads it.
    test "for every stdin exactly one of the two readers reads it" do
      for terminal <- [TtyTerminal, PipedTerminal, __MODULE__.NoRawModeTerminal] do
        masked = with_masked_input("v\n", terminal: terminal).value
        piped = capture_read_stdin("v\n", terminal: terminal)

        assert Enum.count([masked, piped], &match?({:ok, "v"}, &1)) == 1,
               "#{inspect(terminal)}: masked #{inspect(masked)}, --stdin #{inspect(piped)}"
      end
    end

    test "restores the echo state it found rather than forcing echo on" do
      result = with_masked_input("topsecret\n", terminal: __MODULE__.EchoOffTerminal)

      assert result.value == {:ok, "topsecret"}
      assert_received {:secret_input_echo, false}
      assert_received {:secret_input_echo, false}
      refute_received {:secret_input_echo, true}
    end

    test "an echo switch the terminal refuses reads nothing and prompts nothing" do
      result = with_masked_input("topsecret\n", terminal: __MODULE__.EchoRefusedTerminal)

      assert result.value == {:error, {:terminal_setup_failed, :eio}}
      assert result.prompt == ""
      assert result.output == ""
    end

    test "strips exactly one trailing newline" do
      assert %{value: {:ok, " padded "}} = with_masked_input(" padded \n", terminal: TtyTerminal)
      assert %{value: {:ok, "crlf"}} = with_masked_input("crlf\r\n", terminal: TtyTerminal)
    end
  end

  describe "read_stdin/1" do
    test "reads the piped secret and strips exactly one trailing newline" do
      assert capture_read_stdin("topsecret\n", terminal: PipedTerminal) == {:ok, "topsecret"}
      assert capture_read_stdin("topsecret", terminal: PipedTerminal) == {:ok, "topsecret"}
      assert capture_read_stdin("two\n\n", terminal: PipedTerminal) == {:ok, "two\n"}
    end

    test "refuses when stdin is a terminal rather than waiting for an EOF that never comes" do
      assert capture_read_stdin("", terminal: TtyTerminal) == {:error, :stdin_is_a_terminal}
    end

    test "reports an empty stdin instead of storing a blank secret" do
      assert capture_read_stdin("", terminal: PipedTerminal) == {:error, :no_input}
    end
  end

  defmodule EchoOffTerminal do
    @moduledoc false
    @behaviour Fermix.CLI.SecretInput

    @impl true
    def set_echo(echo?) do
      send(self(), {:secret_input_echo, echo?})
      {:ok, false}
    end

    @impl true
    def stdin_terminal?, do: true
  end

  # The shipped 0.15.0 world: stdin is a terminal, and the VM's own no-echo
  # mode answers `:enotsup` because its runtime has no termcap. `enter_raw/0` is
  # what the old reader asked; a reader that keys on stdin never calls it.
  defmodule NoRawModeTerminal do
    @moduledoc false

    def enter_raw, do: {:error, :enotsup}

    def set_echo(echo?) do
      send(self(), {:secret_input_echo, echo?})
      {:ok, true}
    end

    def stdin_terminal?, do: true
  end

  defmodule EchoRefusedTerminal do
    @moduledoc false
    @behaviour Fermix.CLI.SecretInput

    @impl true
    def set_echo(_echo?), do: {:error, :eio}

    @impl true
    def stdin_terminal?, do: true
  end

  # Setup reads its answers one line at a time from whatever stdin is, so a
  # secret question hides the answer on a terminal and takes the next line of
  # a pipe, where nothing echoes it.
  describe "read_answer/2" do
    test "on a terminal, reads the answer with echo off and shows its length" do
      result = with_answer_input("sk-pasted\n", terminal: TtyTerminal)

      assert result.value == {:ok, "sk-pasted"}
      assert result.prompt == "Paste a token: (9 characters)\n"
      assert result.output == ""
      assert_received {:secret_input_echo, false}
      assert_received {:secret_input_echo, true}
    end

    test "from a pipe, reads only the next line and leaves the rest for the next question" do
      result = with_answer_input("sk-piped\nnext answer\n", terminal: PipedTerminal)

      assert result.value == {:ok, "sk-piped"}
      assert result.output == "Paste a token: "
      refute_received {:secret_input_echo, _echo}
    end
  end

  # capture_io runs the function in this process, so the terminal stub's echo
  # messages land in this mailbox and `IO`'s `:standard_io` resolves to the
  # captured group leader.
  defp with_masked_input(input, opts) do
    with_read(input, fn -> SecretInput.read_masked("Paste a token", opts) end)
  end

  defp with_answer_input(input, opts) do
    with_read(input, fn -> SecretInput.read_answer("Paste a token", opts) end)
  end

  defp with_read(input, read) do
    parent = self()
    output_holder = :erlang.make_ref()

    prompt =
      capture_io(:stderr, fn ->
        output =
          capture_io(input, fn ->
            send(parent, {:masked, read.()})
          end)

        send(parent, {output_holder, output})
      end)

    assert_received {:masked, value}
    assert_received {^output_holder, output}
    %{value: value, output: output, prompt: prompt}
  end

  defp capture_read_stdin(input, opts) do
    parent = self()

    capture_io(input, fn -> send(parent, {:stdin, SecretInput.read_stdin(opts)}) end)

    assert_received {:stdin, value}
    value
  end
end
