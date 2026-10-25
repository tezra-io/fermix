defmodule FermixCore.Auth.AnthropicLoginTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.AnthropicLogin
  alias FermixCore.Auth.Store
  alias FermixCore.Management.Jobs

  require AnthropicLogin

  # What `security find-generic-password -g` writes to stdout for the item (an
  # invented account). The password line goes to stderr, which the runner
  # captures in the same stream.
  @claude_code_attributes """
  keychain: "/Users/example/Library/Keychains/login.keychain-db"
  version: 512
  class: "genp"
  attributes:
      0x00000007 <blob>="Claude Code-credentials"
      "acct"<blob>="example"
      "svce"<blob>="Claude Code-credentials"
  """

  # A fresh directory per call, removed when the test ends: a name from
  # `System.unique_integer/1` repeats in the next VM, and a directory an earlier
  # run left behind then still holds that run's files.
  defp tmp_dir do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("anthropic-login")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
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

  # The same login, pretty-printed and holding a name with accents (invented),
  # so its bytes include line breaks and UTF-8.
  defp claude_code_pretty_json(overrides) do
    overrides
    |> claude_code_json()
    |> Jason.decode!()
    |> Map.put("organization", %{"name" => "Café Ünïcode"})
    |> Jason.encode!(pretty: true)
  end

  # The host the keychain read runs on: `security` at its macOS path, and a
  # runner that reports each run to the test and answers `{exit, output}`.
  defp keychain_host(answer) do
    parent = self()

    runner = fn security, args, opts ->
      send(parent, {:keychain_read, security, args, opts})
      {exit, output} = answer.(args)
      {:ok, %{exit: exit, stdout: output, truncated?: false}}
    end

    [security_path: "/usr/bin/security", command_runner: runner]
  end

  # What /usr/bin/security prints, by flag (probed on a throwaway keychain).
  # `-w`: the value, or its bytes as bare lowercase hex when any byte is
  # outside space to tilde. `-g`: the attributes, then `password: ` and the
  # value in quotes when every byte is printable and none is a backslash, or
  # else `0x`, the bytes in uppercase hex, two spaces and the value with octal
  # escapes.
  defp security_prints(args, value) do
    cond do
      "-g" in args and text_form?(value) ->
        @claude_code_attributes <> "password: \"" <> value <> "\"\n"

      "-g" in args ->
        @claude_code_attributes <>
          "password: 0x" <> Base.encode16(value) <> "  \"" <> octal_escaped(value) <> "\"\n"

      "-w" in args and printable?(value) ->
        value <> "\n"

      "-w" in args ->
        Base.encode16(value, case: :lower) <> "\n"
    end
  end

  defp printable?(value), do: for(<<byte <- value>>, do: byte in 0x20..0x7E) |> Enum.all?()
  defp text_form?(value), do: printable?(value) and not String.contains?(value, "\\")

  defp octal_escaped(value) do
    for <<byte <- value>>, into: "" do
      if byte in 0x20..0x7E and byte != ?\\,
        do: <<byte>>,
        else: "\\" <> String.pad_leading(Integer.to_string(byte, 8), 3, "0")
    end
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

    # A sign-in write takes the profile lock (TOKEN-4's sign-in half), so it
    # cannot land inside a refresh of the same profile and be overwritten by it.
    test "waits while a refresh of the anthropic_oauth profile holds its lock" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("anthropic-login-lock")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      path = fermix_path(dir)
      lock = Store.profile_lock_path("anthropic_oauth", path)
      File.write!(lock, "0 a-refresh\n")

      sign_in =
        Task.async(fn ->
          AnthropicLogin.store_setup_token("sk-ant-oat01-xyz", fermix_path: path)
        end)

      assert Task.yield(sign_in, 300) == nil

      FermixTestSupport.SafeRm.rm!(lock)
      assert {:ok, _entry} = Task.await(sign_in)

      assert {:ok, %{tokens: %{access_token: "sk-ant-oat01-xyz"}}} =
               Store.read("anthropic_oauth", path)
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

      assert {:error, {:claude_code_import, :claude_code_credentials_expired}} =
               AnthropicLogin.import_claude_code(
                 credentials_path: creds_path,
                 keychain_reader: fn -> :error end,
                 fermix_path: fermix_path(tmp_dir())
               )
    end

    test "errors when no credential source exists" do
      dir = tmp_dir()

      assert {:error, {:claude_code_import, :no_claude_code_credentials}} =
               AnthropicLogin.import_claude_code(
                 credentials_path: Path.join(dir, "missing.json"),
                 keychain_reader: fn -> :error end,
                 fermix_path: fermix_path(dir)
               )
    end
  end

  # The keychain read without a `:keychain_reader`: the runner stands in for
  # `/usr/bin/security` and answers each flag the way the tool does, so no
  # keychain is reached and the tool need not be installed.
  describe "the keychain read" do
    test "reads the item with -g, so a login holding a line break or UTF-8 arrives exactly" do
      dir = tmp_dir()
      json = claude_code_pretty_json(%{"accessToken" => "kc_at"})
      assert json =~ "\n" and json =~ "é"

      assert {:ok, entry} =
               AnthropicLogin.import_claude_code(
                 keychain_host(fn args -> {0, security_prints(args, json)} end) ++
                   [
                     credentials_path: Path.join(dir, "missing.json"),
                     fermix_path: fermix_path(dir)
                   ]
               )

      assert entry.tokens.access_token == "kc_at"
      assert_received {:keychain_read, "/usr/bin/security", args, _opts}
      assert args == ["find-generic-password", "-s", "Claude Code-credentials", "-g"]
    end

    # Reading another app's item can raise the keychain's allow prompt, and the
    # tree-less CLI has no command host to run it under. The Mac app's import
    # job holds the read and the verifying after it within its budget.
    test "waits half the import job's budget for the allow prompt, under the caller's supervision" do
      dir = tmp_dir()

      assert {:ok, _entry} =
               AnthropicLogin.import_claude_code(
                 keychain_host(fn args -> {0, security_prints(args, claude_code_json())} end) ++
                   [
                     supervised: false,
                     credentials_path: Path.join(dir, "missing.json"),
                     fermix_path: fermix_path(dir)
                   ]
               )

      assert_received {:keychain_read, _security, _args, opts}
      assert opts[:supervised] == false
      assert opts[:timeout_ms] == div(Jobs.budget_ms(:auth_import), 2)
    end

    test "an item the keychain does not hold leaves the credentials file to answer" do
      dir = tmp_dir()
      creds_path = write_credentials(dir, claude_code_json(%{"accessToken" => "file_at"}))
      not_found = "security: SecKeychainSearchCopyNext: The specified item could not be found.\n"

      assert {:ok, entry} =
               AnthropicLogin.import_claude_code(
                 keychain_host(fn _args -> {44, not_found} end) ++
                   [credentials_path: creds_path, fermix_path: fermix_path(dir)]
               )

      assert entry.tokens.access_token == "file_at"
    end

    # The file is Claude Code's store for a host with no keychain login, not a
    # second answer for a keychain that has one and could not hand it over.
    test "an answer in no form security prints is refused, and the file never answers for it" do
      dir = tmp_dir()
      creds_path = write_credentials(dir, claude_code_json(%{"accessToken" => "file_at"}))

      assert {:error, {:claude_code_import, :unreadable_keychain_password}} =
               AnthropicLogin.import_claude_code(
                 keychain_host(fn _args -> {0, @claude_code_attributes} end) ++
                   [credentials_path: creds_path, fermix_path: fermix_path(dir)]
               )
    end

    # The reason keeps the exit status and none of the tool's words, which the
    # password line could be among.
    test "a keychain read that fails is reported, and the file never answers for it" do
      dir = tmp_dir()
      creds_path = write_credentials(dir, claude_code_json(%{"accessToken" => "file_at"}))

      for {exit, said, reason} <- [
            {128, "security: SecKeychainItemCopyContent: User canceled the operation.\n",
             :keychain_read_denied},
            {51,
             "security: SecKeychainItemCopyContent: The user name or passphrase you entered " <>
               "is not correct.\n", :keychain_read_denied},
            {36, "security: SecKeychainItemCopyContent: User interaction is not allowed.\n",
             :keychain_prompt_unavailable},
            {25, "security: SecKeychainItemCopyContent: The specified keychain is invalid.\n",
             {:keychain_read_failed, 25}}
          ] do
        assert AnthropicLogin.import_claude_code(
                 keychain_host(fn _args -> {exit, said} end) ++
                   [credentials_path: creds_path, fermix_path: fermix_path(dir)]
               ) == {:error, {:claude_code_import, reason}}
      end
    end

    test "no security on this host leaves the credentials file to answer" do
      dir = tmp_dir()
      creds_path = write_credentials(dir, claude_code_json(%{"accessToken" => "file_at"}))

      assert {:ok, entry} =
               AnthropicLogin.import_claude_code(
                 security_path: nil,
                 command_runner: fn _security, _args, _opts -> flunk("no security to run") end,
                 credentials_path: creds_path,
                 fermix_path: fermix_path(dir)
               )

      assert entry.tokens.access_token == "file_at"
    end

    # CommandRunner stops reading at its cap; what it read is the start of the
    # answer, which for `-g` is the password line.
    test "an answer cut off at the runner's cap is refused, and the file never answers for it" do
      dir = tmp_dir()
      creds_path = write_credentials(dir, claude_code_json(%{"accessToken" => "file_at"}))

      runner = fn _security, _args, _opts ->
        {:ok, %{exit: 124, stdout: "password: 0x7B22", truncated?: true}}
      end

      assert AnthropicLogin.import_claude_code(
               security_path: "/usr/bin/security",
               command_runner: runner,
               credentials_path: creds_path,
               fermix_path: fermix_path(dir)
             ) == {:error, {:claude_code_import, :helper_output_too_large}}
    end

    test "a prompt nobody answered in time is reported as that, and the file never answers for it" do
      dir = tmp_dir()
      creds_path = write_credentials(dir, claude_code_json(%{"accessToken" => "file_at"}))
      budget = div(Jobs.budget_ms(:auth_import), 2)

      assert AnthropicLogin.import_claude_code(
               security_path: "/usr/bin/security",
               command_runner: fn _security, _args, _opts -> {:error, {:timeout, budget}} end,
               credentials_path: creds_path,
               fermix_path: fermix_path(dir)
             ) == {:error, {:claude_code_import, :keychain_read_timeout}}
    end
  end

  # One sentence per failure, for the Mac app, the browser setup and the CLI.
  describe "failure_sentence/1" do
    test "words every import failure with its own sentence" do
      failures =
        Enum.map(
          [
            :no_claude_code_credentials,
            :claude_code_credentials_invalid,
            :claude_code_credentials_expired,
            :keychain_read_denied,
            :keychain_read_timeout,
            :keychain_prompt_unavailable,
            :unreadable_keychain_password,
            :helper_output_too_large,
            :missing_secret,
            {:keychain_read_failed, 1}
          ],
          &{:claude_code_import, &1}
        )

      assert AnthropicLogin.worded_failures() == failures

      sentences =
        for failure <- failures do
          assert AnthropicLogin.is_import_failure(failure)
          sentence = AnthropicLogin.failure_sentence(failure)
          assert String.ends_with?(sentence, ".")
          refute sentence =~ "security:"
          sentence
        end

      assert length(Enum.uniq(sentences)) == length(failures)

      assert AnthropicLogin.failure_sentence({:claude_code_import, {:keychain_read_failed, 25}}) =~
               "25"
    end

    # The keychain read's reasons share their spelling with SecretWriter's and
    # are only the import's inside its tag, so a failure from anywhere else, a
    # route save's included, is never worded as Claude Code's.
    test "leaves a failure it does not word to the caller" do
      for untagged <- [:missing_secret, :unreadable_keychain_password, :helper_output_too_large] do
        refute AnthropicLogin.is_import_failure(untagged)
      end

      refute AnthropicLogin.is_import_failure(:profile_busy)
      refute AnthropicLogin.is_import_failure({:persist_failed, :eacces})

      refute AnthropicLogin.is_import_failure(
               {:claude_code_import, {:keychain_runner_failed, {:executable_not_found, "x"}}}
             )
    end
  end

  # The presence probe exists because reading the value prompts. A `-g` or a
  # `-w` here would put a macOS allow dialog in front of a daemon request that
  # nobody is watching, so the argv is asserted, not just the answer.
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
      refute "-g" in argv
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
