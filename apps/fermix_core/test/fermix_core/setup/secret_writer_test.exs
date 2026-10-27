defmodule FermixCore.Setup.SecretWriterTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SecretWriterStub

  defmodule UnavailableCandidate do
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: false

    @impl true
    def probe(opts \\ []),
      do: %{store: Keyword.get(opts, :store, :keyring), state: :unavailable, sentence: "double"}

    @impl true
    def put(_key, _value, _opts \\ []), do: {:error, :unavailable}

    @impl true
    def get(_key, _opts \\ []), do: {:error, :unavailable}

    @impl true
    def delete(_key, _opts \\ []), do: {:error, :unavailable}

    @impl true
    def command_source(_key, _opts \\ []),
      do: %{source: :command, command: "/bin/false", args: []}
  end

  defmodule AvailableCandidate do
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def probe(opts \\ []),
      do: %{store: Keyword.get(opts, :store, :keyring), state: :available, sentence: "double"}

    @impl true
    def put(_key, _value, _opts \\ []), do: :ok

    @impl true
    def get(_key, _opts \\ []), do: {:ok, "from-auto"}

    @impl true
    def delete(_key, _opts \\ []), do: :ok

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

  # A `:named_table` belongs to whichever process created it, and under
  # `Task.async_stream` that is a task that exits seconds later — taking the
  # table with it, so a sibling's lookup dies with an ArgumentError. The owner
  # has to be a process that outlives every caller.
  test "the stub table is owned by a durable process, not by its first caller" do
    :ok = SecretWriterStub.put(:openai_api_key, "sk-owner")
    owner = :ets.info(SecretWriterStub, :owner)

    assert is_pid(owner)
    assert Process.alive?(owner)
    refute owner == self()

    task = Task.async(fn -> SecretWriterStub.put(:openai_api_key, "sk-task") end)
    assert :ok = Task.await(task)
    refute Process.alive?(task.pid)

    assert :ets.info(SecretWriterStub, :owner) == owner
    assert {:ok, "sk-task"} = SecretWriterStub.get(:openai_api_key)
  end

  test "concurrent short-lived tasks resolve the stub without an ArgumentError" do
    owner = :ets.info(SecretWriterStub, :owner)

    resolved =
      1..64
      |> Task.async_stream(
        fn n ->
          profile = "concurrent-#{n}"
          :ok = SecretWriterStub.put(:openai_api_key, "sk-#{n}", profile: profile)
          SecretWriterStub.get(:openai_api_key, profile: profile)
        end,
        max_concurrency: 16,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(resolved) == 64
    assert Enum.all?(resolved, &match?({:ok, "sk-" <> _digits}, &1))
    assert :ets.info(SecretWriterStub, :owner) == owner
  end

  test "put raises under test rather than reaching the OS keychain when no writer is configured" do
    # A leaked/cleared :secret_writer app env must never fall back to the Auto ->
    # MacOS writer under test (the historical keychain-clobber path). setup's
    # on_exit restores the stub default.
    Application.delete_env(:fermix_core, :secret_writer)

    assert_raise RuntimeError, ~r/no :secret_writer configured under test/, fn ->
      SecretWriter.put(:openai_api_key, "sk-test")
    end
  end

  test "auto writer selects an available portable candidate" do
    # Configure the Auto writer explicitly: under :test a missing :secret_writer
    # now raises rather than silently falling back to Auto -> the OS keychain.
    Application.put_env(:fermix_core, :secret_writer, SecretWriter.Auto)

    Application.put_env(:fermix_core, :secret_writer_candidates, [
      UnavailableCandidate,
      AvailableCandidate
    ])

    assert SecretWriter.available?()
    assert %{state: :available} = SecretWriter.probe()
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

  describe "keychain coordinate is scoped per profile" do
    setup do
      previous_profile = Application.get_env(:fermix_core, :profile)

      on_exit(fn ->
        case previous_profile do
          nil -> Application.delete_env(:fermix_core, :profile)
          value -> Application.put_env(:fermix_core, :profile, value)
        end
      end)

      :ok
    end

    test "default profile keeps the legacy bare coordinate (no migration)" do
      Application.delete_env(:fermix_core, :profile)

      assert service_flag(SecretWriter.MacOS.command_source(:openai_api_key).args) ==
               "fermix:OPENAI_API_KEY"

      Application.put_env(:fermix_core, :profile, "general")

      assert service_flag(SecretWriter.MacOS.command_source(:openai_api_key).args) ==
               "fermix:OPENAI_API_KEY"
    end

    test "named profile prefixes the macOS entry name" do
      Application.put_env(:fermix_core, :profile, "work")

      assert service_flag(SecretWriter.MacOS.command_source(:telegram_bot_token).args) ==
               "fermix:work:TELEGRAM_BOT_TOKEN"
    end

    test "explicit profile opt overrides the app-env profile" do
      Application.put_env(:fermix_core, :profile, "general")

      assert service_flag(
               SecretWriter.MacOS.command_source(:openai_api_key, profile: "work").args
             ) ==
               "fermix:work:OPENAI_API_KEY"
    end

    test "secret-tool: default bare, named profile prefixed" do
      Application.delete_env(:fermix_core, :profile)

      assert %{command: command, args: bare} =
               SecretWriter.SecretTool.command_source(:openai_api_key)

      assert bare == [
               "lookup",
               "service",
               "fermix",
               "account",
               "fermix",
               "env",
               "OPENAI_API_KEY"
             ]

      assert command == "secret-tool" or String.ends_with?(command, "/secret-tool")

      Application.put_env(:fermix_core, :profile, "work")
      assert %{args: scoped} = SecretWriter.SecretTool.command_source(:openai_api_key)

      assert scoped == [
               "lookup",
               "service",
               "fermix:work",
               "account",
               "fermix",
               "env",
               "OPENAI_API_KEY"
             ]
    end
  end

  describe "macOS put self-heals the keychain ACL" do
    test "deletes the existing item, then re-adds the SAME item with the open -A ACL" do
      [delete, add] = SecretWriter.MacOS.put_commands(:openai_api_key, "sk-secret")

      assert hd(delete) == "delete-generic-password"
      assert hd(add) == "add-generic-password"
      # same account + service on both, so the delete targets exactly what the add
      # recreates — the point is resetting THAT item's ACL, not a different one.
      assert account_flag(delete) == "fermix" and account_flag(add) == "fermix"
      assert service_flag(delete) == service_flag(add)
      # the add re-creates with the open, no-per-app ACL (-A) so headless reads
      # never prompt; -U keeps the value written even if the delete was a no-op.
      assert "-A" in add and "-U" in add
      # and the delete carries no secret to redact
      refute "-w" in delete
    end
  end

  describe "delete/2" do
    # The coordinate assertions below read the active profile, so establish it
    # here rather than inheriting whatever an earlier module left in app env.
    setup do
      previous_profile = Application.get_env(:fermix_core, :profile)
      Application.delete_env(:fermix_core, :profile)

      on_exit(fn ->
        case previous_profile do
          nil -> Application.delete_env(:fermix_core, :profile)
          value -> Application.put_env(:fermix_core, :profile, value)
        end
      end)

      :ok
    end

    test "the facade removes the stored value" do
      assert :ok = SecretWriter.put(:openai_api_key, "sk-test")
      assert :ok = SecretWriter.delete(:openai_api_key)
      assert {:error, :missing_secret} = SecretWriter.get(:openai_api_key)
    end

    test "deleting an absent value succeeds — the postcondition already holds" do
      assert :ok = SecretWriter.delete(:openai_api_key)
    end

    test "the auto writer routes to the selected candidate" do
      Application.put_env(:fermix_core, :secret_writer, SecretWriter.Auto)

      Application.put_env(:fermix_core, :secret_writer_candidates, [
        UnavailableCandidate,
        AvailableCandidate
      ])

      assert :ok = SecretWriter.delete(:openai_api_key)
    end

    test "the none writer refuses rather than reporting a delete it never made" do
      assert {:error, :unavailable} = SecretWriter.None.delete(:openai_api_key)
    end

    test "macOS deletes exactly the item put/3 creates" do
      [delete, _add] = SecretWriter.MacOS.put_commands(:openai_api_key, "sk-secret")
      assert SecretWriter.MacOS.delete_command(:openai_api_key) == delete
    end

    test "macOS treats errSecItemNotFound as done and reports every other failure" do
      assert SecretWriter.MacOS.delete_result({:ok, ""}) == :ok

      assert SecretWriter.MacOS.delete_result(
               {:error, {:helper_failed, "/usr/bin/security", 44, "could not be found"}}
             ) == :ok

      locked = {:helper_failed, "/usr/bin/security", 51, "keychain is locked"}
      assert SecretWriter.MacOS.delete_result({:error, locked}) == {:error, locked}

      timeout = {:helper_timeout, "/usr/bin/security", 3_000}
      assert SecretWriter.MacOS.delete_result({:error, timeout}) == {:error, timeout}
    end

    test "secret-tool clears the same attribute coordinate it looks up" do
      assert SecretWriter.SecretTool.clear_command(:openai_api_key) == [
               "clear",
               "service",
               "fermix",
               "account",
               "fermix",
               "env",
               "OPENAI_API_KEY"
             ]

      assert SecretWriter.SecretTool.clear_command(:openai_api_key, profile: "work") == [
               "clear",
               "service",
               "fermix:work",
               "account",
               "fermix",
               "env",
               "OPENAI_API_KEY"
             ]
    end
  end

  # What /usr/bin/security printed for each invented value, stored the way
  # put/3 stores it (`add-generic-password -a … -s … -w <value> -U -A`) in a
  # throwaway keychain: the line `-g` writes to stderr. `-g` says which form it
  # printed: the text in quotes when every byte is printable and none is a
  # backslash, otherwise `0x` and the uppercase hex, then the text with octal
  # escapes when any byte is printable. (`-w`, which get/2 no longer runs,
  # prints every value of the second kind as bare lowercase hex.)
  @keychain_probe [
    {"printable", "sk-probe-Abc123_xyz.789", ~S|password: "sk-probe-Abc123_xyz.789"|},
    {"quote", "quote\"inside", ~S|password: "quote"inside"|},
    {"only quotes", "\"\"", ~S|password: """"|},
    {"single quote char", "\"", ~S|password: """|},
    {"spaces", "  spaced  ", ~S|password: "  spaced  "|},
    {"all hex", "deadbeef", ~S|password: "deadbeef"|},
    {"starts 0x", "0xCAFE", ~S|password: "0xCAFE"|},
    {"backslash", "back\\slash", ~S|password: 0x6261636B5C736C617368  "back\134slash"|},
    {"quote and backslash", "a\"b\\c", ~S|password: 0x6122625C63  "a"b\134c"|},
    {"newlines", "line one\nline two\nline three",
     ~S|password: 0x6C696E65206F6E650A6C696E652074776F0A6C696E65207468726565  "line one\012line two\012line three"|},
    {"trailing newline", "trail-value\n",
     ~S|password: 0x747261696C2D76616C75650A  "trail-value\012"|},
    {"utf8", "caf\u{E9}-\u{43A}\u{43B}\u{44E}\u{447}-\u{79D8}\u{5BC6}",
     ~S|password: 0x636166C3A92DD0BAD0BBD18ED1872DE7A798E5AF86  "caf\303\251-\320\272\320\273\321\216\321\207-\347\247\230\345\257\206"|},
    {"tab", "a\tb", ~S|password: 0x610962  "a\011b"|},
    {"cr", "carriage\rreturn",
     ~S|password: 0x63617272696167650D72657475726E  "carriage\015return"|},
    {"del byte", "del\x7Fbyte", ~S|password: 0x64656C7F62797465  "del\177byte"|},
    {"looks like g line", "x\"\npassword: \"y",
     ~S|password: 0x78220A70617373776F72643A202279  "x"\012password: "y"|},
    {"only newline", "\n", ~S|password: 0x0A |},
    {"only non ascii", "\u{79D8}\u{5BC6}", ~S|password: 0xE7A798E5AF86 |},
    {"only backslash", "\\", ~S|password: 0x5C |}
  ]

  # `-g` prints the item's attributes on stdout, and the runner captures stderr
  # and stdout as one stream. Which comes first depends on stdio buffering (a
  # dump past the 64 KiB buffer can split a row around the password line), so
  # the parser never relies on it: it takes the one line that starts with
  # `password: ` and refuses an answer with none, several, or one in neither
  # form. The fixtures put the line first, as the probe saw it.
  @attribute_dump """
  keychain: "/Users/example/Library/Keychains/login.keychain-db"
  version: 256
  class: "genp"
  attributes:
      0x00000007 <blob>="fermix:OPENAI_API_KEY"
      0x00000008 <blob>=<NULL>
      "acct"<blob>="fermix"
      "cdat"<timedate>=0x32303236313032353139353835315A00  "20261025195851Z\\000"
      "crtr"<uint32>=<NULL>
      "cusi"<sint32>=<NULL>
      "desc"<blob>=<NULL>
      "gena"<blob>=<NULL>
      "icmt"<blob>=<NULL>
      "invi"<sint32>=<NULL>
      "mdat"<timedate>=0x32303236313032353139353835315A00  "20261025195851Z\\000"
      "nega"<sint32>=<NULL>
      "prot"<blob>=<NULL>
      "scrp"<sint32>=<NULL>
      "svce"<blob>="fermix:OPENAI_API_KEY"
      "type"<uint32>=<NULL>
  """

  describe "macOS get/2 reads back exactly the stored bytes" do
    for {label, value, g_line} <- @keychain_probe do
      test "a value that is #{label}" do
        args = SecretWriter.MacOS.get_command(:openai_api_key)
        answer = security_prints(args, unquote(g_line))

        assert SecretWriter.MacOS.get_result(answer) == {:ok, unquote(value)}
      end
    end

    test "it reads with -g, which marks the form it printed, never with -w" do
      args = SecretWriter.MacOS.get_command(:openai_api_key)

      assert "-g" in args
      refute "-w" in args
    end

    test "an empty stored value is no secret" do
      args = SecretWriter.MacOS.get_command(:openai_api_key)
      answer = security_prints(args, "password: ")

      assert SecretWriter.MacOS.get_result(answer) == {:error, :missing_secret}
    end

    test "a helper failure passes through unchanged, a missing item included" do
      missing =
        {:helper_failed, "/usr/bin/security find-generic-password", 44,
         "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n"}

      timeout = {:helper_timeout, "/usr/bin/security find-generic-password", 3_000}

      assert SecretWriter.MacOS.get_result({:error, missing}) == {:error, missing}
      assert SecretWriter.MacOS.get_result({:error, timeout}) == {:error, timeout}
    end

    # The reason is an atom: an answer that is refused never carries the value.
    test "an answer in no form security prints is refused, never guessed at" do
      for output <- [
            @attribute_dump,
            ~S|password: "first"| <> "\n" <> ~S|password: "second"| <> "\n",
            ~S|password: "unterminated| <> "\n",
            ~S|password: "back\slash"| <> "\n",
            ~S|password: ""| <> "\n",
            "password: 0x6162\n",
            "password: 0x616 \n",
            "password: 0x6G62 \n",
            "password: 0x6c6c \n",
            ~S|password: 0x6162  "ab| <> "\n",
            ~S|password: deadbeef| <> "\n"
          ] do
        assert SecretWriter.MacOS.get_result({:ok, output <> @attribute_dump}) ==
                 {:error, :unreadable_keychain_password},
               inspect(output)
      end
    end

    test "the refusal reads as a sentence at boot" do
      assert SecretWriter.format_error(:openai_api_key, :unreadable_keychain_password) ==
               "OPENAI_API_KEY could not be resolved from @keyring: the login Keychain " <>
                 "answered in a form Fermix does not read, so nothing was used"
    end

    test "get/2 runs -g through the runner and hands its answer to the parser" do
      parent = self()

      runner = fn binary, args, _opts ->
        send(parent, {:ran, binary, args})
        {:ok, answer} = security_prints(args, ~S|password: 0x0A |)
        {:ok, %{exit: 0, stdout: answer, truncated?: false}}
      end

      assert SecretWriter.MacOS.get(:openai_api_key, host_opts("security", runner)) ==
               {:ok, "\n"}

      assert_received {:ran, "/usr/bin/security", ["find-generic-password" | _] = args}
      assert "-g" in args
    end
  end

  # libsecret's `secret-tool lookup` writes the secret's bytes, and a newline
  # after them only when its stdout is a terminal (tool/secret-tool.c,
  # write_password_stdout: `if (isatty (1))`, the same from 0.18 to 0.21.8).
  # The runner's stdout is a pipe, so what it captured is the stored value.
  describe "secret-tool get/2 reads back exactly the stored bytes" do
    for {label, value} <- [
          {"plain", "sk-invented"},
          {"ended by a newline", "pem-body\n"},
          {"ended by two newlines", "pem-body\n\n"},
          {"only a newline", "\n"}
        ] do
      test "a value that is #{label}" do
        runner = fn _binary, ["lookup" | _attributes], _opts ->
          {:ok, %{exit: 0, stdout: unquote(value), truncated?: false}}
        end

        assert SecretWriter.SecretTool.get(:openai_api_key, host_opts("secret-tool", runner)) ==
                 {:ok, unquote(value)}
      end
    end

    test "an empty stored value is no secret" do
      runner = fn _binary, ["lookup" | _attributes], _opts ->
        {:ok, %{exit: 0, stdout: "", truncated?: false}}
      end

      assert SecretWriter.SecretTool.get(:openai_api_key, host_opts("secret-tool", runner)) ==
               {:error, :missing_secret}
    end
  end

  # CommandRunner stops reading at 1 MiB and reports the run as exit 124,
  # truncated. What it read is the start of the answer, which for `security -g`
  # is the password line and for `secret-tool lookup` the secret itself, so a
  # reason that kept any of it would carry the secret into a log line.
  describe "an answer cut off at the output cap" do
    @cut_off_secret "password: 0x" <> String.duplicate("4B", 64)

    test "macOS refuses it and keeps none of it" do
      runner = fn _binary, _args, _opts ->
        {:ok, %{exit: 124, stdout: @cut_off_secret, truncated?: true}}
      end

      assert SecretWriter.MacOS.get(:openai_api_key, host_opts("security", runner)) ==
               {:error, :helper_output_too_large}
    end

    test "secret-tool refuses it and keeps none of it" do
      runner = fn _binary, _args, _opts ->
        {:ok, %{exit: 124, stdout: "sk-invented-secret-start", truncated?: true}}
      end

      assert SecretWriter.SecretTool.get(:openai_api_key, host_opts("secret-tool", runner)) ==
               {:error, :helper_output_too_large}
    end

    test "the refusal reads as a sentence at boot, naming no output" do
      assert SecretWriter.format_error(:openai_api_key, :helper_output_too_large) ==
               "OPENAI_API_KEY could not be resolved from @keyring: the secret helper " <>
                 "answered with more than Fermix reads, so none of it was used"
    end
  end

  # M45 §4.1: a skill's own credential is addressed by name, in a namespace of
  # its own, so storing or removing a skill's `OPENAI_API_KEY` can never reach
  # the provider's registry item of the same variable name.
  describe "an external env key" do
    setup do
      previous_profile = Application.get_env(:fermix_core, :profile)
      Application.delete_env(:fermix_core, :profile)

      on_exit(fn ->
        case previous_profile do
          nil -> Application.delete_env(:fermix_core, :profile)
          value -> Application.put_env(:fermix_core, :profile, value)
        end
      end)

      :ok
    end

    test "round-trips through the facade beside a registry key of the same name" do
      assert :ok = SecretWriter.put(:openai_api_key, "sk-provider")
      assert :ok = SecretWriter.put({:external_env, "OPENAI_API_KEY"}, "sk-skill")

      assert SecretWriter.get({:external_env, "OPENAI_API_KEY"}) == {:ok, "sk-skill"}
      assert SecretWriter.get(:openai_api_key) == {:ok, "sk-provider"}

      assert :ok = SecretWriter.delete({:external_env, "OPENAI_API_KEY"})
      assert SecretWriter.get({:external_env, "OPENAI_API_KEY"}) == {:error, :missing_secret}
      assert SecretWriter.get(:openai_api_key) == {:ok, "sk-provider"}
    end

    test "macOS addresses its own service, never the provider's" do
      [delete, add] = SecretWriter.MacOS.put_commands({:external_env, "OPENAI_API_KEY"}, "v")

      assert service_flag(delete) == "fermix:external_env:OPENAI_API_KEY"
      assert service_flag(add) == "fermix:external_env:OPENAI_API_KEY"
      assert account_flag(add) == "fermix"
      assert "-A" in add and "-U" in add

      refute service_flag(SecretWriter.MacOS.delete_command(:openai_api_key)) ==
               service_flag(SecretWriter.MacOS.delete_command({:external_env, "OPENAI_API_KEY"}))

      assert %{source: :command, args: lookup, timeout_ms: 3_000} =
               SecretWriter.MacOS.command_source({:external_env, "OPENAI_API_KEY"})

      assert lookup == [
               "find-generic-password",
               "-a",
               "fermix",
               "-s",
               "fermix:external_env:OPENAI_API_KEY",
               "-w"
             ]
    end

    test "macOS scopes the service to a named profile" do
      assert service_flag(
               SecretWriter.MacOS.delete_command({:external_env, "X"}, profile: "work")
             ) == "fermix:work:external_env:X"

      Application.put_env(:fermix_core, :profile, "work")

      assert service_flag(SecretWriter.MacOS.command_source({:external_env, "X"}).args) ==
               "fermix:work:external_env:X"
    end

    test "secret-tool addresses the same logical reference by attribute" do
      assert SecretWriter.SecretTool.clear_command({:external_env, "X"}) ==
               ["clear", "service", "fermix", "account", "fermix", "env", "external_env:X"]

      assert SecretWriter.SecretTool.clear_command({:external_env, "X"}, profile: "work") ==
               ["clear", "service", "fermix:work", "account", "fermix", "env", "external_env:X"]

      assert %{args: lookup} =
               SecretWriter.SecretTool.command_source({:external_env, "X"}, profile: "work")

      assert lookup ==
               ["lookup", "service", "fermix:work", "account", "fermix", "env", "external_env:X"]
    end

    test "the auto writer routes an external key to the selected candidate" do
      Application.put_env(:fermix_core, :secret_writer, SecretWriter.Auto)

      Application.put_env(:fermix_core, :secret_writer_candidates, [
        UnavailableCandidate,
        AvailableCandidate
      ])

      assert :ok = SecretWriter.put({:external_env, "X"}, "v")
      assert {:ok, "from-auto"} = SecretWriter.get({:external_env, "X"})
      assert :ok = SecretWriter.delete({:external_env, "X"})
    end

    # A name is validated before any I/O by the management call; a caller that
    # skipped it is a defect, and building a keychain address from it would be
    # the silent half of that defect.
    test "a name that fails validation never becomes an address" do
      for name <- ["MY-VAR", "PATH", "", "LC_ALL"] do
        assert_raise ArgumentError, fn ->
          SecretWriter.MacOS.delete_command({:external_env, name})
        end

        assert_raise ArgumentError, fn ->
          SecretWriter.SecretTool.clear_command({:external_env, name})
        end
      end
    end

    test "a key that is neither shape is refused at the facade" do
      assert_raise FunctionClauseError, fn -> SecretWriter.get({:external_env, :X}) end
      assert_raise FunctionClauseError, fn -> SecretWriter.put({:other, "X"}, "v") end
    end
  end

  # M60 §6.2: one secret field of a cue source, under `cue_source:<ref>:<field>`.
  describe "a cue source key" do
    setup do
      previous_profile = Application.get_env(:fermix_core, :profile)
      Application.delete_env(:fermix_core, :profile)

      on_exit(fn ->
        case previous_profile do
          nil -> Application.delete_env(:fermix_core, :profile)
          value -> Application.put_env(:fermix_core, :profile, value)
        end
      end)

      :ok
    end

    test "round-trips through the facade, one item per source and field" do
      assert :ok = SecretWriter.put({:cue_source, "home-alerts", :token}, "tok-a")
      assert :ok = SecretWriter.put({:cue_source, "other", :token}, "tok-b")
      assert :ok = SecretWriter.put({:cue_source, "home-alerts", :key}, "key-a")

      assert SecretWriter.get({:cue_source, "home-alerts", :token}) == {:ok, "tok-a"}
      assert SecretWriter.get({:cue_source, "other", :token}) == {:ok, "tok-b"}
      assert SecretWriter.get({:cue_source, "home-alerts", :key}) == {:ok, "key-a"}

      assert :ok = SecretWriter.delete({:cue_source, "home-alerts", :token})
      assert SecretWriter.get({:cue_source, "home-alerts", :token}) == {:error, :missing_secret}
    end

    test "is filed under cue_source:<ref>:<field> in both OS stores" do
      key = {:cue_source, "home-alerts", :token}
      assert SecretWriter.item_name(key) == "cue_source:home-alerts:token"

      [_delete, add] = SecretWriter.MacOS.put_commands(key, "v")
      assert service_flag(add) == "fermix:cue_source:home-alerts:token"

      assert service_flag(SecretWriter.MacOS.delete_command(key, profile: "work")) ==
               "fermix:work:cue_source:home-alerts:token"

      assert SecretWriter.SecretTool.clear_command(key) ==
               [
                 "clear",
                 "service",
                 "fermix",
                 "account",
                 "fermix",
                 "env",
                 "cue_source:home-alerts:token"
               ]
    end

    test "a ref that is not a source name never becomes an address" do
      for ref <- ["Home", "a:b", "a/b", "", "-x", String.duplicate("a", 65)] do
        assert_raise ArgumentError, fn ->
          SecretWriter.MacOS.delete_command({:cue_source, ref, :token})
        end
      end
    end

    test "a field outside token, key and secret is refused at the facade" do
      assert_raise FunctionClauseError, fn ->
        SecretWriter.get({:cue_source, "home-alerts", :password})
      end

      assert_raise FunctionClauseError, fn ->
        SecretWriter.put({:cue_source, "home-alerts", "token"}, "v")
      end
    end
  end

  # The machine a writer finds its tool on and runs it with, so no keychain or
  # keyring is reached and the tool need not be installed.
  defp host_opts(tool, runner) do
    [find_executable: fn ^tool -> "/usr/bin/" <> tool end, command_runner: runner]
  end

  # What `security -g` answers, as CommandRunner captures it: the password line,
  # then the attribute dump. The fixtures are `-g` answers, so the flag is checked.
  defp security_prints(args, g_line) do
    assert "-g" in args
    {:ok, g_line <> "\n" <> @attribute_dump}
  end

  defp service_flag(args), do: flag_value(args, "-s")
  defp account_flag(args), do: flag_value(args, "-a")

  defp flag_value(args, flag) do
    index = Enum.find_index(args, &(&1 == flag))
    Enum.at(args, index + 1)
  end
end
