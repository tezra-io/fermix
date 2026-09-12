defmodule FermixCore.Setup.SecretWriteLogTest do
  @moduledoc """
  The one path every setup secret write takes (M34 native setup §7.5).

  Its whole reason to exist is that a rotation is invisible afterwards: the
  sentinel written over the sentinel leaves both restart baselines unchanged.
  These cases prove the write still happens, the record is made, and the record
  is what a boot-bound comparison can read.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Setup.SecretWriteLog
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SecretWriterStub
  alias FermixTestSupport.UnavailableSecretWriter

  setup do
    writer = Application.get_env(:fermix_core, :secret_writer)
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()

    on_exit(fn ->
      case writer do
        nil -> Application.delete_env(:fermix_core, :secret_writer)
        value -> Application.put_env(:fermix_core, :secret_writer, value)
      end

      SecretWriterStub.reset()
    end)

    %{log: start_log()}
  end

  test "the value reaches the writer and the write is recorded", %{log: log} do
    assert SecretWriteLog.put(:openai_api_key, "sk-one", write_log: log) == :ok

    assert SecretWriter.get(:openai_api_key) == {:ok, "sk-one"}
    assert [%{key: :openai_api_key}] = SecretWriteLog.recorded(write_log: log)
  end

  # Read against the recorded times rather than a wall-clock guess: two writes
  # in one millisecond are ordinary, and a marker taken between them would make
  # this case depend on how fast the machine is.
  test "keys_since answers the writes at or after the marker and nothing before it", %{log: log} do
    assert SecretWriteLog.put(:openai_api_key, "sk-one", write_log: log) == :ok
    assert SecretWriteLog.put(:telegram_bot_token, "1:abc", write_log: log) == :ok

    [newest, oldest] = SecretWriteLog.recorded(write_log: log)

    assert SecretWriteLog.keys_since(oldest.at_ms, write_log: log) == [
             :telegram_bot_token,
             :openai_api_key
           ]

    assert SecretWriteLog.keys_since(newest.at_ms + 1, write_log: log) == []
  end

  # A failed write replaced nothing, so recording it would ask for a restart
  # that applies a credential the machine does not hold.
  test "a refused write records nothing and returns the writer's own reason", %{log: log} do
    Application.put_env(:fermix_core, :secret_writer, UnavailableSecretWriter)

    assert SecretWriteLog.put(:openai_api_key, "sk-one", write_log: log) ==
             {:error, :unavailable}

    assert SecretWriteLog.recorded(write_log: log) == []
  end

  # Two declared configurations of one read, not a fallback: the write itself
  # always happens, and a process that never started has nothing to report.
  test "with no log running the write still lands and the record is empty" do
    assert SecretWriteLog.put(:openai_api_key, "sk-one", write_log: :write_log_absent) == :ok
    assert SecretWriter.get(:openai_api_key) == {:ok, "sk-one"}
    assert SecretWriteLog.keys_since(0, write_log: :write_log_absent) == []
  end

  test "the record is bounded so a rotating daemon cannot grow it without end" do
    log = start_log(max_recorded: 2)

    for value <- ~w(one two three) do
      assert SecretWriteLog.put(:openai_api_key, "sk-" <> value, write_log: log) == :ok
    end

    assert length(SecretWriteLog.recorded(write_log: log)) == 2
  end

  # "No log running" and "the log is wedged or failing" are different facts.
  # Answering the empty list for the second one tells the restart comparison
  # that nothing was rotated, which is exactly the silence this module exists to
  # break, so anything that is not an absent process is raised at the caller.
  test "a failing log is raised at the caller, not read as an empty record" do
    log = failing_log()

    assert {:failing, _call} = catch_exit(SecretWriteLog.keys_since(0, write_log: log))
  end

  # Registered, so `Process.whereis` answers, and dies on the call rather than
  # replying — the shape of a log that is present but cannot serve.
  defp failing_log do
    name = :"secret_write_log_failing_#{System.unique_integer([:positive, :monotonic])}"

    pid =
      spawn(fn ->
        receive do
          _message -> exit(:failing)
        end
      end)

    Process.register(pid, name)
    name
  end

  defp start_log(opts \\ []) do
    name = :"secret_write_log_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({SecretWriteLog, [name: name] ++ opts}, id: name)
    name
  end
end
