defmodule FermixCore.Setup.SecretWriterTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SecretWriterStub

  defmodule UnavailableCandidate do
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: false

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

  defp service_flag(args), do: flag_value(args, "-s")
  defp account_flag(args), do: flag_value(args, "-a")

  defp flag_value(args, flag) do
    index = Enum.find_index(args, &(&1 == flag))
    Enum.at(args, index + 1)
  end
end
