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
    FermixTestSupport.SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :secret_writer)
        value -> Application.put_env(:fermix_core, :secret_writer, value)
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
    candidates = [UnavailableCandidate, AvailableCandidate]

    assert SecretWriter.available?(candidates: candidates)
    assert :ok = SecretWriter.put(:openai_api_key, "sk-test", candidates: candidates)
    assert {:ok, "from-auto"} = SecretWriter.get(:openai_api_key, candidates: candidates)

    assert %{command: "/bin/fake-keyring", args: ["openai_api_key"]} =
             SecretWriter.command_source(:openai_api_key, candidates: candidates)
  end
end
