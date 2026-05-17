defmodule FermixCore.Setup.SecretWriterTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.SecretWriter

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
end
