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
      assert result.prompt == "Paste a token: \n"
      refute result.prompt =~ "topsecret"
      # The prompt is a notice, so a `--json` verb's stdout stays parseable.
      assert result.output == ""
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
      # Nothing was prompted and nothing was consumed.
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

  # capture_io runs the function in this process, so the terminal stub's echo
  # messages land in this mailbox and `IO`'s `:standard_io` resolves to the
  # captured group leader.
  defp with_masked_input(input, opts) do
    parent = self()
    output_holder = :erlang.make_ref()

    prompt =
      capture_io(:stderr, fn ->
        output =
          capture_io(input, fn ->
            send(parent, {:masked, SecretInput.read_masked("Paste a token", opts)})
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
