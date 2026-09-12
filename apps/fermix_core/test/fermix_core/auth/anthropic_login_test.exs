defmodule FermixCore.Auth.AnthropicLoginTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.Store

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "fermix_anthropic_login_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    dir
  end

  defp fermix_path(dir), do: Path.join(dir, "auth.json")

  defp future_ms(seconds), do: System.os_time(:millisecond) + seconds * 1000

  defp claude_code_json(overrides \\ %{}) do
    Jason.encode!(%{
      "claudeAiOauth" =>
        Map.merge(
          %{
            "accessToken" => "cc_at",
            "refreshToken" => "cc_rt",
            "expiresAt" => future_ms(3600),
            "scopes" => ["user:inference", "user:profile"]
          },
          overrides
        )
    })
  end

  defp write_credentials(dir, json) do
    path = Path.join(dir, "credentials.json")
    File.write!(path, json)
    path
  end

  describe "store_setup_token/2" do
    test "persists the token under the anthropic_oauth profile with provider anthropic" do
      dir = tmp_dir()
      path = fermix_path(dir)

      assert {:ok, entry} =
               AnthropicLogin.store_setup_token("sk-ant-oat01-xyz", fermix_path: path)

      assert entry.auth_mode == "setup_token"
      assert entry.provider == "anthropic"
      assert entry.tokens.access_token == "sk-ant-oat01-xyz"
      assert entry.tokens.refresh_token == nil
      assert entry.expires_at == nil

      assert {:ok, stored} = Store.read("anthropic_oauth", path)
      assert stored.tokens.access_token == "sk-ant-oat01-xyz"
      assert stored.provider == "anthropic"
    end

    test "rejects a blank token" do
      assert_raise ArgumentError, fn ->
        AnthropicLogin.store_setup_token("   ", fermix_path: fermix_path(tmp_dir()))
      end
    end

    test "re-login clears a stale reauthorization_required quarantine" do
      dir = tmp_dir()
      path = fermix_path(dir)

      :ok =
        Store.write(
          "anthropic_oauth",
          %{
            auth_mode: "claude_code_import",
            provider: "anthropic",
            tokens: %{access_token: "dead-at", refresh_token: "dead-rt"},
            expires_at: nil,
            last_refresh: nil,
            status: "reauthorization_required"
          },
          path
        )

      assert {:ok, _entry} =
               AnthropicLogin.store_setup_token("sk-ant-fresh", fermix_path: path)

      assert {:ok, stored} = Store.read("anthropic_oauth", path)
      assert stored.tokens.access_token == "sk-ant-fresh"
      # Store.put_provider merges over the existing entry and drops nil keys,
      # so the quarantine flag survives unless re-login writes "ready".
      assert stored.status == "ready"
    end
  end

  describe "import_claude_code/1" do
    test "imports credentials from the Claude Code credentials file" do
      dir = tmp_dir()
      creds_path = write_credentials(dir, claude_code_json())
      path = fermix_path(dir)

      assert {:ok, entry} =
               AnthropicLogin.import_claude_code(
                 credentials_path: creds_path,
                 keychain_reader: fn -> :error end,
                 fermix_path: path
               )

      assert entry.auth_mode == "claude_code_import"
      assert entry.provider == "anthropic"
      assert entry.tokens.access_token == "cc_at"
      assert entry.tokens.refresh_token == "cc_rt"
      assert %DateTime{} = entry.expires_at
      assert entry.granted_scopes == ["user:inference", "user:profile"]

      assert {:ok, stored} = Store.read("anthropic_oauth", path)
      assert stored.tokens.access_token == "cc_at"
    end

    test "prefers the keychain reader over the credentials file" do
      dir = tmp_dir()
      creds_path = write_credentials(dir, claude_code_json(%{"accessToken" => "file_at"}))

      assert {:ok, entry} =
               AnthropicLogin.import_claude_code(
                 credentials_path: creds_path,
                 keychain_reader: fn -> {:ok, claude_code_json(%{"accessToken" => "kc_at"})} end,
                 fermix_path: fermix_path(dir)
               )

      assert entry.tokens.access_token == "kc_at"
    end

    test "imports expired credentials when a refresh token is present" do
      dir = tmp_dir()

      creds_path =
        write_credentials(dir, claude_code_json(%{"expiresAt" => future_ms(-3600)}))

      assert {:ok, entry} =
               AnthropicLogin.import_claude_code(
                 credentials_path: creds_path,
                 keychain_reader: fn -> :error end,
                 fermix_path: fermix_path(dir)
               )

      assert entry.tokens.refresh_token == "cc_rt"
    end

    test "rejects expired credentials without a refresh token" do
      dir = tmp_dir()

      creds_path =
        write_credentials(
          dir,
          claude_code_json(%{"expiresAt" => future_ms(-3600), "refreshToken" => nil})
        )

      assert {:error, :claude_code_credentials_expired} =
               AnthropicLogin.import_claude_code(
                 credentials_path: creds_path,
                 keychain_reader: fn -> :error end,
                 fermix_path: fermix_path(tmp_dir())
               )
    end

    test "errors when no credential source exists" do
      dir = tmp_dir()

      assert {:error, :no_claude_code_credentials} =
               AnthropicLogin.import_claude_code(
                 credentials_path: Path.join(dir, "missing.json"),
                 keychain_reader: fn -> :error end,
                 fermix_path: fermix_path(dir)
               )
    end
  end

  describe "claude_code_available?/1" do
    test "true when a credential source parses, false otherwise" do
      dir = tmp_dir()
      creds_path = write_credentials(dir, claude_code_json())

      assert AnthropicLogin.claude_code_available?(
               credentials_path: creds_path,
               keychain_reader: fn -> :error end
             )

      refute AnthropicLogin.claude_code_available?(
               credentials_path: Path.join(dir, "missing.json"),
               keychain_reader: fn -> :error end
             )
    end
  end

  # The presence probe exists because reading the value prompts. A `-w` here
  # would put a macOS allow dialog in front of a daemon request that nobody is
  # watching, so the argv is asserted, not just the answer.
  describe "claude_code_present?/1" do
    test "asks the keychain whether the item exists and never for its value" do
      dir = tmp_dir()
      log = Path.join(dir, "argv.log")

      assert AnthropicLogin.claude_code_present?(
               security_path: fake_security(dir, log, 0),
               credentials_path: Path.join(dir, "missing.json")
             )

      argv = File.read!(log) |> String.split("\n", trim: true)

      assert argv == ["find-generic-password", "-s", "Claude Code-credentials"]
      refute "-w" in argv
    end

    test "an item the keychain does not hold is not present" do
      dir = tmp_dir()

      refute AnthropicLogin.claude_code_present?(
               security_path: fake_security(dir, Path.join(dir, "argv.log"), 44),
               credentials_path: Path.join(dir, "missing.json")
             )
    end

    # The credentials file is the second store Claude Code itself uses, so a
    # Linux host with no keychain still answers truthfully.
    test "the credentials file alone is presence" do
      dir = tmp_dir()

      assert AnthropicLogin.claude_code_present?(
               keychain_present?: fn -> false end,
               credentials_path: write_credentials(dir, claude_code_json())
             )
    end

    test "no security binary on this host is not presence" do
      dir = tmp_dir()

      refute AnthropicLogin.claude_code_present?(
               security_path: nil,
               credentials_path: Path.join(dir, "missing.json")
             )
    end
  end

  defp fake_security(dir, log, exit_status) do
    path = Path.join(dir, "security")

    File.write!(path, """
    #!/bin/sh
    for arg in "$@"; do printf '%s\\n' "$arg" >> #{log}; done
    exit #{exit_status}
    """)

    File.chmod!(path, 0o755)
    path
  end
end
