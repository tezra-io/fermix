defmodule FermixCore.Setup.SecretWriterTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.SecretWriter

  defmodule UnavailableCandidate do
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: false

    @impl true
    def put(_key, _value, _opts \\ []), do: {:error, :unavailable}

    @impl true
    def get(_key, _opts \\ []), do: {:error, :unavailable}

    @impl true
    def command_source(_key, _opts \\ []),
      do: %{source: :command, command: "/bin/false", args: []}
  end

  defmodule AvailableCandidate do
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def put(_key, _value, _opts \\ []), do: :ok

    @impl true
    def get(_key, _opts \\ []), do: {:ok, "from-auto"}

    @impl true
    def command_source(key, _opts \\ []) do
      %{source: :command, command: "/bin/fake-keyring", args: [Atom.to_string(key)]}
    end
  end

  setup do
    previous = Application.get_env(:fermix_core, :secret_writer)
    previous_candidates = Application.get_env(:fermix_core, :secret_writer_candidates)
    FermixTestSupport.SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :secret_writer)
        value -> Application.put_env(:fermix_core, :secret_writer, value)
      end

      case previous_candidates do
        nil -> Application.delete_env(:fermix_core, :secret_writer_candidates)
        value -> Application.put_env(:fermix_core, :secret_writer_candidates, value)
      end

      FermixTestSupport.SecretWriterStub.reset()
    end)

    :ok
  end

  test "stub round-trips setup secret values through the facade" do
    assert :ok = SecretWriter.put(:openai_api_key, "sk-test")
    assert {:ok, "sk-test"} = SecretWriter.get(:openai_api_key)
  end

  test "auto writer selects an available portable candidate" do
    Application.delete_env(:fermix_core, :secret_writer)

    Application.put_env(:fermix_core, :secret_writer_candidates, [
      UnavailableCandidate,
      AvailableCandidate
    ])

    assert SecretWriter.available?()
    assert :ok = SecretWriter.put(:openai_api_key, "sk-test")
    assert {:ok, "from-auto"} = SecretWriter.get(:openai_api_key)

    assert %{command: "/bin/fake-keyring", args: ["openai_api_key"]} =
             SecretWriter.command_source(:openai_api_key)
  end

  test "format_error trims helper output" do
    reason = {:helper_failed, "/bin/keyring lookup", 44, "missing secret\n"}

    assert SecretWriter.format_error(:tavily_api_key, reason) ==
             "TAVILY_API_KEY could not be resolved from @keyring: " <>
               "/bin/keyring lookup exited 44: missing secret"
  end

  test "secret-tool command source uses linux secret-tool lookup attributes" do
    assert %{
             command: command,
             args: ["lookup", "service", "fermix", "account", "fermix", "env", "OPENAI_API_KEY"]
           } = SecretWriter.SecretTool.command_source(:openai_api_key)

    assert command == "secret-tool" or String.ends_with?(command, "/secret-tool")
  end
end
