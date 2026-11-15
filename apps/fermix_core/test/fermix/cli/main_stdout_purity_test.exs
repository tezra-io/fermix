defmodule Fermix.CLI.MainStdoutPurityTest do
  # `Fermix.CLI.main/1` moves the default logger handler off stdout before it
  # dispatches any argv whose stdout is a wire (`StdoutPurity.wire_stdout?/1`).
  # In a release the `logger` application starts after `config/runtime.exs`
  # made that move: it removes the default handler and installs its own on
  # stdout, so the boot chain's move never reaches the verb, and a `--json`
  # verb that logs puts the line ahead of its envelope. `mix test` runs with
  # no default handler, so each case installs one (level `:none`: nothing it
  # is handed is written) and puts back exactly what was there before. Not
  # async: the handler belongs to the whole VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.StdoutPurity

  # A handler that is not `:logger_std_h`, which the move cannot rewrite.
  defmodule ForeignHandler do
    @moduledoc false
    def log(_event, _config), do: :ok
  end

  setup do
    original = :logger.get_handler_config(:default)
    on_exit(fn -> restore(original) end)
    :ok
  end

  describe "main/1" do
    test "an argv asking for --json runs with the default handler on stderr" do
      install(:logger_std_h, %{type: :standard_io})

      capture_io(fn -> assert Fermix.CLI.main(["help", "--json"]) == 0 end)

      assert {:ok, %{module: :logger_std_h, config: %{type: :standard_error}}} =
               :logger.get_handler_config(:default)
    end

    test "any other argv leaves the default handler where it is" do
      install(:logger_std_h, %{type: :standard_io})

      capture_io(fn -> assert Fermix.CLI.main(["help"]) == 0 end)

      assert {:ok, %{module: :logger_std_h, config: %{type: :standard_io}}} =
               :logger.get_handler_config(:default)
    end

    test "a handler it cannot move runs no verb: one sentence on stderr, exit 1" do
      install(ForeignHandler, %{})
      parent = self()

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn -> send(parent, {:status, Fermix.CLI.main(["help", "--json"])}) end)

          send(parent, {:stdout, stdout})
        end)

      assert_received {:status, 1}
      # The usage text `help` prints never appeared: no verb ran.
      assert_received {:stdout, ""}

      assert stderr ==
               "fermix: the default logger handler is #{inspect(ForeignHandler)}, which " <>
                 "Fermix cannot move off stdout, and a wire on stdout must carry nothing " <>
                 "else, so the command did not run.\n"

      assert {:ok, %{module: ForeignHandler}} = :logger.get_handler_config(:default)
    end
  end

  describe "StdoutPurity.wire_stdout?/1" do
    test "a wire verb, or --json anywhere in argv" do
      assert StdoutPurity.wire_stdout?(["acp"])
      assert StdoutPurity.wire_stdout?(["acp", "forget", "--all"])
      assert StdoutPurity.wire_stdout?(["browser-bridge", "--manifest", "m.json", "o"])
      assert StdoutPurity.wire_stdout?(["home", "status", "--json"])
      assert StdoutPurity.wire_stdout?(["settings", "--json", "list"])
    end

    test "nothing else" do
      refute StdoutPurity.wire_stdout?([])
      refute StdoutPurity.wire_stdout?(["home", "status"])
      refute StdoutPurity.wire_stdout?(["browser", "bridge", "status"])
      refute StdoutPurity.wire_stdout?(["ask", "say acp"])
    end
  end

  defp install(module, config) do
    remove_default()
    :ok = :logger.add_handler(:default, module, %{level: :none, config: config})
  end

  defp restore(original) do
    remove_default()

    case original do
      {:ok, config} ->
        {module, rest} = Map.pop!(config, :module)
        :ok = :logger.add_handler(:default, module, rest)

      {:error, {:not_found, :default}} ->
        :ok
    end
  end

  defp remove_default do
    case :logger.remove_handler(:default) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
    end
  end
end
