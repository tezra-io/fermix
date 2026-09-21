defmodule FermixCore.Management.SecretsMigrateTest do
  use ExUnit.Case, async: false

  alias FermixCore.Management.Secrets
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SecretWriterStub

  setup do
    home =
      Path.join(System.tmp_dir!(), "fermix-mgmt-migrate-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    SecretWriterStub.reset()
    previous = Application.get_env(:fermix_core, :secret_writer)
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf(home)

      case previous do
        nil -> Application.delete_env(:fermix_core, :secret_writer)
        value -> Application.put_env(:fermix_core, :secret_writer, value)
      end
    end)

    {:ok, opts: [home: home]}
  end

  # One identifier per secret on the wire. `OPENAI_API_KEY` is how a store
  # files the value, not what the secret is called: a client that took `moved`
  # and handed an entry back to `secret.clear` would be refused by its own
  # engine, and a client that showed the list to a person would show them
  # environment variable names for secrets they know by another name.
  test "moved names secrets the way secret.set takes them, not the way a store files them", %{
    opts: opts
  } do
    :ok = SecretWriter.put(:openai_api_key, "sk-value", [store: :file] ++ opts)

    assert {:ok, %{"moved" => moved, "store" => "keyring"}} = Secrets.migrate_to_keyring(opts)

    assert moved == ["openai_api_key"]
    assert Enum.all?(moved, &(&1 in Secrets.ids()))
  end

  test "a home with nothing in the file store answers an empty list", %{opts: opts} do
    assert {:ok, %{"moved" => [], "store" => "keyring"}} = Secrets.migrate_to_keyring(opts)
  end
end
