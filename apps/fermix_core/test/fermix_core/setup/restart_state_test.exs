defmodule FermixCore.Setup.RestartStateTest do
  @moduledoc """
  The two-baseline gates from M34 native setup §7.5, seeded rather than argued.

  Every case establishes its own home and its own application environment in
  `setup` and restores both in `on_exit`: the answers under test are derived
  from global state, so a case that read what an earlier module left behind
  would pass or fail on test order.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretWriteLog
  alias FermixTestSupport.SafeRm

  @env_keys [:providers, :personalization, :agent, :realtime, :harness, :meetings]

  setup do
    home = System.get_env("FERMIX_HOME")
    core = Map.new(@env_keys, fn key -> {key, Application.get_env(:fermix_core, key)} end)
    telegram = Application.get_env(:fermix_channels, :telegram)
    secret_writer = Application.get_env(:fermix_core, :secret_writer)

    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)
    FermixTestSupport.SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("restart_state_home")
    System.put_env("FERMIX_HOME", tmp)

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(:fermix_core, key, value) end)
      restore(:fermix_channels, :telegram, telegram)
      restore(:fermix_core, :secret_writer, secret_writer)
      FermixTestSupport.SecretWriterStub.reset()

      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(tmp)
    end)

    %{home: tmp}
  end

  describe "a home with no settings file" do
    test "reports clear and needs no restart before the first save" do
      server = start_state()

      assert RestartState.config_state(server: server) == :clear
      assert RestartState.restart(server: server) == %{required: false, reasons: []}
    end

    # The two-baseline proof. `current_snapshot/0` carries the compiled
    # `telegram: [enabled: true]` default while a parsed file with no telegram
    # block carries `telegram: []`, so a single baseline reports a phantom
    # `channels` reason or a phantom external change on every fresh install.
    test "a 0.9.x file with no channel block is still clear and needs no restart", %{home: home} do
      File.write!(Path.join(home, "config.toml"), """
      [fermix_core.providers.openai]
      default_model = "gpt-5.6"
      """)

      Application.put_env(:fermix_channels, :telegram, enabled: true)
      server = start_state()

      assert RestartState.config_state(server: server) == :clear
      assert RestartState.restart(server: server) == %{required: false, reasons: []}
    end
  end

  describe "boot-bound changes" do
    test "a section changed since boot is a reason with the daemon's own sentence" do
      server = start_state()
      Application.put_env(:fermix_core, :realtime, enabled: true)

      assert %{required: true, reasons: [reason]} = RestartState.restart(server: server)
      assert reason.section == "realtime"
      assert reason.sentence == "Voice settings changed since Fermix started."
    end

    # `lifecycle.commit` runs the daemon's shutdown path, so the boot baseline
    # resets by the process starting again. A reset that did not also restart
    # the daemon would report "no restart needed" for a change still not applied.
    test "restarting the state re-captures the boot baseline and clears the reasons" do
      server = start_state()
      Application.put_env(:fermix_core, :realtime, enabled: true)
      assert %{required: true} = RestartState.restart(server: server)

      restarted = start_state()
      assert RestartState.restart(server: restarted) == %{required: false, reasons: []}
    end

    test "every published section carries a sentence in sentence case" do
      for {section, sentence} <- RestartState.boot_bound_sections() do
        assert is_atom(section)
        assert String.ends_with?(sentence, "."), "#{section} sentence is not a sentence"
        refute sentence =~ "—", "#{section} sentence carries an em dash"
        refute sentence =~ "!", "#{section} sentence carries an exclamation mark"
      end
    end
  end

  describe "a secret replaced since boot" do
    # The fourth input, and the one neither baseline can see: a rotation writes
    # the same `@keyring` sentinel over the same sentinel, so the document and
    # application environment are identical before and after.
    test "a boot-bound key is a restart reason under its own section" do
      log = start_write_log()
      server = start_state(write_log: log)
      assert RestartState.restart(server: server) == %{required: false, reasons: []}

      assert SecretWriteLog.put(:openai_api_key, "sk-rotated", write_log: log) == :ok

      assert %{required: true, reasons: [reason]} = RestartState.restart(server: server)
      assert reason.section == "providers"
    end

    test "a channel token is a restart reason under channels" do
      log = start_write_log()
      server = start_state(write_log: log)

      assert SecretWriteLog.put(:telegram_bot_token, "1:abc", write_log: log) == :ok

      assert %{required: true, reasons: [reason]} = RestartState.restart(server: server)
      assert reason.section == "channels"
    end

    # A search key is read per call, so rotating it needs no restart. A blanket
    # "any secret write means restart" would ask for one on every key.
    test "a key whose section is read per call is no reason at all" do
      log = start_write_log()
      server = start_state(write_log: log)

      assert SecretWriteLog.put(:tavily_api_key, "tvly-1", write_log: log) == :ok

      assert RestartState.restart(server: server) == %{required: false, reasons: []}
    end
  end

  describe "a file written from outside" do
    test "reports external_change, and recording the baseline clears it", %{home: home} do
      path = Path.join(home, "config.toml")
      File.write!(path, "[fermix_core.providers.openai]\ndefault_model = \"gpt-5.6\"\n")
      server = start_state()
      assert RestartState.config_state(server: server) == :clear

      File.write!(path, "[fermix_core.providers.openai]\ndefault_model = \"gpt-5.6-sol\"\n")
      assert {:external_change, sections} = RestartState.config_state(server: server)
      assert "providers" in sections

      # The third writer: without it the one action offered to clear the state
      # would leave the baseline where it was and the refusal would stand.
      assert RestartState.record_persisted_baseline(server: server) == :ok
      assert RestartState.config_state(server: server) == :clear
    end

    test "an external change is a restart reason of its own", %{home: home} do
      path = Path.join(home, "config.toml")
      File.write!(path, "[fermix_core.providers.openai]\ndefault_model = \"gpt-5.6\"\n")
      server = start_state()

      File.write!(path, "[fermix_core.providers.openai]\ndefault_model = \"gpt-5.6-sol\"\n")

      assert %{required: true, reasons: reasons} = RestartState.restart(server: server)
      assert Enum.any?(reasons, &(&1.section == "settings_file"))
    end

    test "a second external write after a reload is a fresh change, never a latch", %{home: home} do
      path = Path.join(home, "config.toml")
      File.write!(path, "[fermix_core.providers.openai]\ndefault_model = \"a\"\n")
      server = start_state()

      File.write!(path, "[fermix_core.providers.openai]\ndefault_model = \"b\"\n")
      assert {:external_change, _sections} = RestartState.config_state(server: server)
      assert RestartState.record_persisted_baseline(server: server) == :ok
      assert RestartState.config_state(server: server) == :clear

      File.write!(path, "[fermix_core.providers.openai]\ndefault_model = \"c\"\n")
      assert {:external_change, _again} = RestartState.config_state(server: server)
    end

    test "reverting an external edit clears the state with no reload", %{home: home} do
      path = Path.join(home, "config.toml")
      original = "[fermix_core.providers.openai]\ndefault_model = \"a\"\n"
      File.write!(path, original)
      server = start_state()

      File.write!(path, "[fermix_core.providers.openai]\ndefault_model = \"b\"\n")
      assert {:external_change, _sections} = RestartState.config_state(server: server)

      File.write!(path, original)
      assert RestartState.config_state(server: server) == :clear
    end
  end

  describe "a file that cannot be parsed" do
    # `load_runtime_config/1` raises rather than returns for a poisoned file, and
    # an uncaught raise would take `/health`, `overview.get` and every write
    # result with it, so the daemon could not render the state that explains the
    # problem.
    test "reports config_unreadable with the parser's own sentence, and still answers", %{
      home: home
    } do
      File.write!(Path.join(home, "config.toml"), "[fermix_core.providers]\nopenai = 5\n")
      server = start_state()

      assert {:config_unreadable, sentence} = RestartState.config_state(server: server)
      assert is_binary(sentence) and sentence != ""
      assert %{required: _required, reasons: _reasons} = RestartState.restart(server: server)
    end

    # The parser's ArgumentError message IS the operator's sentence; a function
    # clause message is not — it names an internal function and would be shown
    # verbatim under a banner the operator cannot act on.
    test "a wrong-shape value is published in the daemon's own words", %{home: home} do
      File.write!(Path.join(home, "config.toml"), "[fermix_core.providers]\nopenai = 5\n")
      server = start_state()

      assert {:config_unreadable, sentence} = RestartState.config_state(server: server)

      refute sentence =~ "no function clause"
      refute sentence =~ "FermixCore."
      refute sentence =~ "/2"
    end

    test "an operator-facing parse refusal keeps the parser's own sentence", %{home: home} do
      File.write!(Path.join(home, "config.toml"), "[fermix_core.transcription]\nnosuch = 1\n")
      server = start_state()

      assert {:config_unreadable, sentence} = RestartState.config_state(server: server)
      assert sentence =~ "nosuch"
    end
  end

  # A baseline describes one file. Reporting every section of a freshly
  # pointed-at home as an outside change would invent a fact rather than admit
  # there is no baseline for it yet.
  test "a home change re-establishes the baseline instead of reporting a change", %{home: home} do
    File.write!(
      Path.join(home, "config.toml"),
      "[fermix_core.providers.openai]\ndefault_model = \"a\"\n"
    )

    server = start_state()
    assert RestartState.config_state(server: server) == :clear

    other = SafeRm.make_tmp_dir!("restart_state_other_home")
    on_exit(fn -> SafeRm.rm_rf!(other) end)

    File.write!(
      Path.join(other, "config.toml"),
      "[fermix_core.providers.openai]\ndefault_model = \"z\"\n"
    )

    System.put_env("FERMIX_HOME", other)

    assert RestartState.config_state(server: server) == :clear
  end

  describe "with no server running" do
    # A tree-less verb has read nothing and started nothing. That is two declared
    # configurations of one read, not a fallback chain.
    test "answers clear and no restart rather than guessing" do
      assert RestartState.config_state(server: :restart_state_absent) == :clear

      assert RestartState.restart(server: :restart_state_absent) == %{
               required: false,
               reasons: []
             }

      assert RestartState.record_persisted_baseline(server: :restart_state_absent) == :ok
    end
  end

  test "previous_config_path names the kept file only when one exists", %{home: home} do
    assert RestartState.previous_config_path() == nil

    path = Path.join(home, "config.toml.previous")
    File.write!(path, "")
    assert RestartState.previous_config_path() == path
  end

  # `cache_ttl_ms: 0` so a case can write the file and read the answer in the
  # same millisecond. The cache is a polled-read bound, not part of the
  # behaviour under test, and its own expiry is covered by the default.
  defp start_state(opts \\ []) do
    name = :"restart_state_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({RestartState, [name: name, cache_ttl_ms: 0] ++ opts}, id: name)
    name
  end

  defp start_write_log do
    name = :"secret_write_log_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({SecretWriteLog, name: name}, id: name)
    name
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
