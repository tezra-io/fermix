defmodule FermixCore.Capabilities.MCP.SecretsTest do
  @moduledoc """
  The `mcp:` family's one owner (M74 E6): how a value an operator MCP server
  declares is addressed, written, read, deleted and reported present. Every
  store here is the stub, or the file store under the case's own home.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Secrets
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @stdio %{name: "files", transport: :stdio, env_secrets: ["GITHUB_TOKEN", "API_KEY"]}
  @http %{
    name: "linear",
    transport: :http,
    header_secrets: ["Authorization", "X-Workspace"],
    oauth_client_id: "fermix-client"
  }

  setup do
    writer = Application.get_env(:fermix_core, :secret_writer)
    profile = Application.get_env(:fermix_core, :profile)
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    on_exit(fn ->
      SecretWriterStub.reset()
      Application.put_env(:fermix_core, :secret_writer, writer)
      restore(:profile, profile)
    end)
  end

  describe "ids" do
    test "each kind of id names its server and value, and spells back the same" do
      for {id, ref} <- [
            {"mcp:files/env/GITHUB_TOKEN", {:env, "GITHUB_TOKEN"}},
            {"mcp:linear/header/X-Api-Key", {:header, "X-Api-Key"}},
            {"mcp:linear/client_secret", :client_secret}
          ] do
        assert {:ok, server, ^ref} = Secrets.parse_id(id)
        assert Secrets.id(server, ref) == id
      end
    end

    test "an id outside the grammar is not one" do
      for id <- [
            "mcp:files/env/1TOKEN",
            "mcp:Files/env/TOKEN",
            "mcp:files/header/Bad Header",
            "mcp:files/env/A/B",
            "mcp:files/secret",
            "mcp:files",
            "env:TOKEN"
          ] do
        assert Secrets.parse_id(id) == :error, "expected #{inspect(id)} to be refused"
      end
    end

    # The store files the value under the id itself, behind the profile prefix
    # every Fermix item carries, the way `env:<NAME>` is `external_env:<NAME>`.
    test "the store item is the id, and an unvalidated id never becomes an address" do
      key = Secrets.key("files", {:env, "GITHUB_TOKEN"})

      assert key == {:mcp, "mcp:files/env/GITHUB_TOKEN"}
      assert SecretWriter.item_name(key) == "mcp:files/env/GITHUB_TOKEN"

      assert_raise ArgumentError, fn -> SecretWriter.item_name({:mcp, "mcp:files/../x"}) end
    end
  end

  describe "declared values" do
    test "a stdio server declares its variables, an http one its headers and client secret" do
      assert Secrets.declared(@stdio) == [{:env, "GITHUB_TOKEN"}, {:env, "API_KEY"}]

      assert Secrets.declared(@http) ==
               [{:header, "Authorization"}, {:header, "X-Workspace"}, :client_secret]

      refute :client_secret in Secrets.declared(%{@http | oauth_client_id: nil})
      refute Secrets.declares?(@stdio, {:env, "OTHER"})
    end
  end

  describe "storing" do
    test "a value is stored under its id in the active profile and read back" do
      assert :ok = Secrets.put("files", {:env, "GITHUB_TOKEN"}, "ghp live value")
      assert Secrets.fetch("files", {:env, "GITHUB_TOKEN"}) == {:ok, "ghp live value"}

      assert SecretWriter.get({:mcp, "mcp:files/env/GITHUB_TOKEN"}) == {:ok, "ghp live value"}

      assert SecretWriter.get({:mcp, "mcp:files/env/GITHUB_TOKEN"}, profile: "work") ==
               {:error, :missing_secret}
    end

    test "a pasted Bearer scheme is not stored with an Authorization key" do
      assert :ok = Secrets.put("linear", {:header, "Authorization"}, "Bearer lin_api_123")
      assert Secrets.fetch("linear", {:header, "Authorization"}) == {:ok, "lin_api_123"}

      assert :ok = Secrets.put("linear", {:header, "X-Workspace"}, "Bearer kept")
      assert Secrets.fetch("linear", {:header, "X-Workspace"}) == {:ok, "Bearer kept"}

      assert Secrets.put("linear", {:header, "Authorization"}, "Bearer  ") ==
               {:error, :empty_value}
    end

    test "a value is one line of at most 8,192 bytes" do
      assert Secrets.validate_value("") == {:error, :empty_value}
      assert Secrets.validate_value("a\nb") == {:error, :value_not_single_line}
      assert Secrets.validate_value(String.duplicate("a", 8_193)) == {:error, :value_too_large}
      assert Secrets.validate_value("a value with spaces, \"quotes\" and \\ slashes") == :ok
    end

    # The file store keeps one file per secret, so the id's slashes may not
    # become directories.
    test "the file store holds a value as one plain file" do
      home = SafeRm.make_tmp_dir!("mcp-secrets-file-store")
      on_exit(fn -> SafeRm.rm_rf!(home) end)
      key = Secrets.key("files", {:env, "GITHUB_TOKEN"})

      assert :ok = SecretWriter.File.put(key, "file value", home: home)
      assert SecretWriter.File.get(key, home: home) == {:ok, "file value"}
      assert SecretWriter.File.stored(home: home) == ["mcp.files.env.GITHUB_TOKEN"]
    end
  end

  describe "presence" do
    test "each declared value is present exactly when it can be read" do
      assert :ok = Secrets.put("files", {:env, "API_KEY"}, "k")

      assert Secrets.presence(@stdio) ==
               %{
                 env: [{"GITHUB_TOKEN", false}, {"API_KEY", true}],
                 headers: [],
                 client_secret: false
               }

      refute Secrets.complete?(@stdio)

      assert :ok = Secrets.put("files", {:env, "GITHUB_TOKEN"}, "t")
      assert Secrets.complete?(@stdio)
    end

    test "an http server reports its headers and client secret" do
      assert :ok = Secrets.put("linear", :client_secret, "s")

      assert Secrets.presence(@http) == %{
               env: [],
               headers: [{"Authorization", false}, {"X-Workspace", false}],
               client_secret: true
             }
    end

    test "a value the store refuses to read is not present" do
      assert :ok = Secrets.put("files", {:env, "API_KEY"}, "k")

      SecretWriterStub.set_verdict(%{store: :keyring, state: :locked, sentence: "locked"})
      on_exit(fn -> SecretWriterStub.clear_verdict(:keyring) end)

      assert %{env: [{"GITHUB_TOKEN", false}, {"API_KEY", false}]} = Secrets.presence(@stdio)
    end
  end

  describe "deleting" do
    test "every declared value is deleted, and only those" do
      assert :ok = Secrets.put("files", {:env, "GITHUB_TOKEN"}, "t")
      assert :ok = Secrets.put("files", {:env, "API_KEY"}, "k")
      assert :ok = Secrets.put("other", {:env, "GITHUB_TOKEN"}, "kept")

      assert :ok = Secrets.delete_declared(@stdio)

      assert Secrets.fetch("files", {:env, "GITHUB_TOKEN"}) == {:error, :missing_secret}
      assert Secrets.fetch("files", {:env, "API_KEY"}) == {:error, :missing_secret}
      assert Secrets.fetch("other", {:env, "GITHUB_TOKEN"}) == {:ok, "kept"}
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
