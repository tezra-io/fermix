defmodule Mix.Tasks.Fermix.Cues.SecretTest do
  # async: false — FERMIX_HOME, the Mix shell and the stub writer are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias FermixTestSupport.PipedTerminal
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub
  alias FermixTestSupport.TreeLessSecretWriter
  alias FermixTestSupport.TtyTerminal
  alias Mix.Tasks.Fermix.Cues.Secret, as: SecretTask

  setup do
    home = System.get_env("FERMIX_HOME")
    writer = Application.get_env(:fermix_core, :secret_writer)
    shell = Mix.shell()

    tmp = SafeRm.make_tmp_dir!("cues_secret_task_home")
    System.put_env("FERMIX_HOME", tmp)
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Application.put_env(:fermix_core, :secret_writer, writer)
      SecretWriterStub.reset()
      Mix.shell(shell)
    end)

    File.write!(Path.join(tmp, "config.toml"), """
    [fermix_core]
    profile = "work"

    [fermix_core.cues.sources.home-alerts]
    kind = "local_push"
    token = "@file"

    [fermix_core.cues.sources.eng-blogs]
    preset = "rss"
    url = "https://example.org/feed.xml"
    """)

    %{home: tmp}
  end

  defp piped(value) do
    {:ok, device} = StringIO.open(value)
    [terminal: PipedTerminal, device: device]
  end

  test "stores the piped value in the store the source's sentinel names, for the home's profile" do
    assert :ok = SecretTask.execute(["home-alerts", "token"], piped("tok-1\n"))

    assert SecretWriterStub.get({:cue_source, "home-alerts", :token},
             store: :file,
             profile: "work"
           ) ==
             {:ok, "tok-1"}

    assert SecretWriterStub.get({:cue_source, "home-alerts", :token},
             store: :keyring,
             profile: "work"
           ) ==
             {:error, :missing_secret}

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "Stored cue_source:home-alerts:token in the file store."
    refute message =~ "tok-1"
  end

  test "reads the value with echo off on a terminal" do
    {:ok, device} = StringIO.open("tok-2\n")

    prompt =
      capture_io(:stderr, fn ->
        assert :ok =
                 SecretTask.execute(["home-alerts", "token"],
                   terminal: TtyTerminal,
                   device: device
                 )
      end)

    assert prompt =~ "cue_source:home-alerts:token"
    refute prompt =~ "tok-2"

    assert_received {:secret_input_echo, false}
    assert_received {:secret_input_echo, true}

    assert SecretWriterStub.get({:cue_source, "home-alerts", :token},
             store: :file,
             profile: "work"
           ) ==
             {:ok, "tok-2"}
  end

  # A tree-less Mix task has no command host: every keychain call it makes must
  # say `supervised: false`, or an installed keyring helper would raise.
  test "writes without the daemon tree" do
    Application.put_env(:fermix_core, :secret_writer, TreeLessSecretWriter)
    TreeLessSecretWriter.watch()

    assert :ok = SecretTask.execute(["home-alerts", "token"], piped("tok-3\n"))
    assert_received {:tree_less_keychain, :put, {:cue_source, "home-alerts", :token}}
  end

  test "refuses what it cannot store, and stores nothing" do
    cases = [
      {["home-alerts"], ~r/usage/},
      {["home-alerts", "password"], ~r/usage/},
      {["Home", "token"], ~r/not a source name/},
      {["nope", "token"], ~r/There is no source nope/},
      {["eng-blogs", "key"], ~r/Source eng-blogs has no key field/}
    ]

    for {args, pattern} <- cases do
      assert_raise Mix.Error, pattern, fn -> SecretTask.execute(args, piped("v\n")) end
    end

    assert_raise Mix.Error, ~r/No value was entered/, fn ->
      SecretTask.execute(["home-alerts", "token"], piped("\n"))
    end

    assert SecretWriterStub.get({:cue_source, "home-alerts", :token},
             store: :file,
             profile: "work"
           ) ==
             {:error, :missing_secret}
  end
end
