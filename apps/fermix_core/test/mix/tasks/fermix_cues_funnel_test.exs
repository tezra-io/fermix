defmodule Mix.Tasks.Fermix.Cues.FunnelTest do
  # async: false — FERMIX_HOME, the Mix shell and the stub writer are global.
  use ExUnit.Case, async: false

  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub
  alias FermixTestSupport.TreeLessSecretWriter
  alias Mix.Tasks.Fermix.Cues.Funnel

  @random "R4nd0m-path_secret0123"
  @path "/cues/hooks/gh-hooks/" <> @random
  @target "http://127.0.0.1:4555" <> @path
  @host "mac-alpha.tail1234.ts.net"
  @mount ["funnel", "--bg", "--set-path=" <> @path, @target]
  @status_args ["status", "--json"]
  @funnel_status_args ["funnel", "status", "--json"]

  setup do
    home = System.get_env("FERMIX_HOME")
    writer = Application.get_env(:fermix_core, :secret_writer)
    shell = Mix.shell()

    tmp = SafeRm.make_tmp_dir!("cues_funnel_task_home")
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
      SafeRm.rm_rf!(tmp)
    end)

    File.write!(Path.join(tmp, "config.toml"), """
    [fermix_core]
    profile = "work"

    [fermix_core.cues]
    door_port = 4555

    [fermix_core.cues.sources.gh-hooks]
    preset = "github"
    secret = "@file"
    path_secret = "@file"

    [fermix_core.cues.sources.fresh-hooks]
    preset = "github"
    secret = "@file"

    [fermix_core.cues.sources.off-hooks]
    preset = "github"
    enabled = false
    secret = "@file"
    path_secret = "@file"

    [fermix_core.cues.sources.home-alerts]
    kind = "local_push"
    token = "@file"
    """)

    for ref <- ["gh-hooks", "off-hooks"] do
      :ok =
        SecretWriterStub.put({:cue_source, ref, :path_secret}, @random,
          store: :file,
          profile: "work"
        )
    end

    :ok
  end

  defp running_status(caps \\ %{"funnel" => nil, "https" => nil}) do
    Jason.encode!(%{
      "BackendState" => "Running",
      "Self" => %{"DNSName" => @host <> ".", "CapMap" => caps}
    })
  end

  defp serve_config(handlers, extra \\ %{}) do
    Map.merge(
      %{
        "TCP" => %{"443" => %{"HTTPS" => true}},
        "Web" => %{"#{@host}:443" => %{"Handlers" => handlers}},
        "AllowFunnel" => %{"#{@host}:443" => true}
      },
      extra
    )
    |> Jason.encode!()
  end

  # A stand-in for the tailscale CLI: answers from `responses` (args => reply),
  # tells the test every call, and refuses anything it was not given.
  defp runner(responses) do
    test = self()

    fn args ->
      send(test, {:tailscale, args})

      case Map.fetch(responses, args) do
        {:ok, reply} -> reply
        :error -> flunk("unexpected tailscale call: #{inspect(args)}")
      end
    end
  end

  defp reads(funnel_status \\ "{}", status \\ running_status()) do
    %{@status_args => {status, 0}, @funnel_status_args => {funnel_status, 0}}
  end

  defp info_lines(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> info_lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "mounting" do
    test "prints the exact command and the URL, and changes nothing without --apply" do
      assert :ok = Funnel.execute(["gh-hooks"], runner: runner(reads()))

      lines = Enum.join(info_lines(), "\n")
      assert lines =~ "tailscale funnel --bg --set-path=#{@path} #{@target}"
      assert lines =~ "https://#{@host}#{@path}"
      assert lines =~ "--apply"

      assert_received {:tailscale, @status_args}
      assert_received {:tailscale, @funnel_status_args}
      refute_received {:tailscale, _other}
    end

    test "with --apply runs exactly that command, the same path on both sides" do
      responses =
        Map.put(reads(), @mount, {"Available on the internet:\nhttps://#{@host}#{@path}\n", 0})

      assert :ok = Funnel.execute(["gh-hooks", "--apply"], runner: runner(responses))

      assert_received {:tailscale, @mount}
      assert String.starts_with?(@path, "/cues/hooks/")
      assert Enum.join(info_lines(), "\n") =~ "https://#{@host}#{@path}"
    end

    test "mounts beside Fermix's own mounts for other sources" do
      other = "/cues/hooks/other-hooks/Zz9"
      funnel = serve_config(%{other => %{"Proxy" => "http://127.0.0.1:4555" <> other}})
      responses = Map.put(reads(funnel), @mount, {"", 0})

      assert :ok = Funnel.execute(["gh-hooks", "--apply"], runner: runner(responses))
      assert_received {:tailscale, @mount}
    end

    test "refuses a port that carries a mount Fermix did not make" do
      funnel = serve_config(%{"/" => %{"Proxy" => "http://127.0.0.1:3000"}})

      error =
        assert_raise Mix.Error, fn ->
          Funnel.execute(["gh-hooks", "--apply"], runner: runner(reads(funnel)))
        end

      assert error.message =~ "carries a mount Fermix did not make"
      assert error.message =~ "/ -> http://127.0.0.1:3000"
      refute_received {:tailscale, @mount}
    end

    test "a /cues/hooks path that proxies elsewhere is not Fermix's" do
      funnel = serve_config(%{@path => %{"Proxy" => "http://192.0.2.7:4555" <> @path}})

      assert_raise Mix.Error, ~r/did not make/, fn ->
        Funnel.execute(["gh-hooks", "--apply"], runner: runner(reads(funnel)))
      end
    end

    test "refuses a port that forwards raw TCP, and a foreground session's mount" do
      tcp = Jason.encode!(%{"TCP" => %{"443" => %{"TCPForward" => "127.0.0.1:22"}}})

      assert_raise Mix.Error, ~r/forwards port 443/, fn ->
        Funnel.execute(["gh-hooks", "--apply"], runner: runner(reads(tcp)))
      end

      foreground =
        Jason.encode!(%{
          "Foreground" => %{
            "session-1" => %{
              "Web" => %{"#{@host}:443" => %{"Handlers" => %{"/app" => %{"Text" => "hi"}}}}
            }
          }
        })

      assert_raise Mix.Error, ~r/did not make/, fn ->
        Funnel.execute(["gh-hooks", "--apply"], runner: runner(reads(foreground)))
      end

      refute_received {:tailscale, @mount}
    end

    test "a source already mounted at its path is left alone" do
      funnel = serve_config(%{@path => %{"Proxy" => @target}})

      assert :ok = Funnel.execute(["gh-hooks", "--apply"], runner: runner(reads(funnel)))
      assert Enum.join(info_lines(), "\n") =~ "already mounted"
      refute_received {:tailscale, @mount}
    end

    test "a source mounted at an older path must be removed first" do
      old = "/cues/hooks/gh-hooks/0ldRandom"
      funnel = serve_config(%{old => %{"Proxy" => "http://127.0.0.1:4555" <> old}})

      assert_raise Mix.Error, ~r/already has a Funnel mount at #{old}.*--remove/s, fn ->
        Funnel.execute(["gh-hooks", "--apply"], runner: runner(reads(funnel)))
      end
    end

    test "refuses when Tailscale is not running or Funnel is not allowed here" do
      stopped = Jason.encode!(%{"BackendState" => "Stopped", "Self" => %{}})

      assert_raise Mix.Error, ~r/Tailscale is not running \(Stopped\)/, fn ->
        Funnel.execute(["gh-hooks"], runner: runner(reads("{}", stopped)))
      end

      assert_raise Mix.Error, ~r/Funnel is not allowed for this machine/, fn ->
        Funnel.execute(["gh-hooks"],
          runner: runner(reads("{}", running_status(%{"https" => nil})))
        )
      end

      allowed = running_status(%{"https://tailscale.com/cap/funnel-ports?ports=443,8443" => nil})
      assert :ok = Funnel.execute(["gh-hooks"], runner: runner(reads("{}", allowed)))
    end

    test "refuses a source it cannot mount, before asking Tailscale anything" do
      cases = [
        {["fresh-hooks"], ~r/fresh-hooks has no URL yet/},
        {["off-hooks"], ~r/off-hooks is disabled/},
        {["home-alerts"], ~r/home-alerts is a local_push source/},
        {["nope"], ~r/There is no source nope/}
      ]

      for {args, pattern} <- cases do
        assert_raise Mix.Error, pattern, fn -> Funnel.execute(args, runner: runner(%{})) end
      end

      refute_received {:tailscale, _args}
    end

    test "a failing tailscale command is reported with its own words" do
      responses = Map.put(reads(), @mount, {"error: Funnel not available on this port\n", 1})

      assert_raise Mix.Error, ~r/Funnel not available on this port/, fn ->
        Funnel.execute(["gh-hooks", "--apply"], runner: runner(responses))
      end
    end

    test "no tailscale on PATH, or a status it cannot read, is said so" do
      assert_raise Mix.Error, ~r/tailscale is not installed or not on PATH/, fn ->
        Funnel.execute(["gh-hooks"], runner: fn _args -> {:error, :not_found} end)
      end

      assert_raise Mix.Error, ~r/could not read `tailscale funnel status --json`/, fn ->
        Funnel.execute(["gh-hooks"], runner: runner(reads("not json")))
      end
    end

    test "reads the path secret without the daemon tree" do
      Application.put_env(:fermix_core, :secret_writer, TreeLessSecretWriter)
      TreeLessSecretWriter.watch()

      assert :ok = Funnel.execute(["gh-hooks"], runner: runner(reads()))
      assert_received {:tree_less_keychain, :get, {:cue_source, "gh-hooks", :path_secret}}
    end
  end

  describe "removing" do
    test "--remove finds every mount of the source, prints its command and runs it with --apply" do
      old = "/cues/hooks/gh-hooks/0ldRandom"
      other = "/cues/hooks/other-hooks/Zz9"

      funnel =
        serve_config(%{
          @path => %{"Proxy" => @target},
          old => %{"Proxy" => "http://127.0.0.1:4032" <> old},
          other => %{"Proxy" => "http://127.0.0.1:4555" <> other}
        })

      off_current = ["funnel", "--https=443", "--set-path=" <> @path, "off"]
      off_old = ["funnel", "--https=443", "--set-path=" <> old, "off"]

      assert :ok = Funnel.execute(["gh-hooks", "--remove"], runner: runner(reads(funnel)))
      lines = Enum.join(info_lines(), "\n")
      assert lines =~ "tailscale funnel --https=443 --set-path=#{@path} off"
      assert lines =~ "tailscale funnel --https=443 --set-path=#{old} off"
      refute_received {:tailscale, ["funnel", "--https=443" | _rest]}

      responses = reads(funnel) |> Map.put(off_current, {"", 0}) |> Map.put(off_old, {"", 0})
      assert :ok = Funnel.execute(["gh-hooks", "--remove", "--apply"], runner: runner(responses))

      assert_received {:tailscale, ^off_current}
      assert_received {:tailscale, ^off_old}
      refute_received {:tailscale, ["funnel", "--https=443", "--set-path=" <> ^other, "off"]}
    end

    test "--remove works for a source no longer in the config, and says when there is nothing" do
      gone = "/cues/hooks/gone-hooks/Abc"
      funnel = serve_config(%{gone => %{"Proxy" => "http://127.0.0.1:4555" <> gone}})
      off = ["funnel", "--https=443", "--set-path=" <> gone, "off"]

      responses = Map.put(reads(funnel), off, {"", 0})

      assert :ok =
               Funnel.execute(["gone-hooks", "--remove", "--apply"], runner: runner(responses))

      assert_received {:tailscale, ^off}

      assert :ok = Funnel.execute(["gh-hooks", "--remove"], runner: runner(reads()))
      assert Enum.join(info_lines(), "\n") =~ "gh-hooks has no Funnel mount"
    end
  end

  test "usage errors" do
    for args <- [[], ["Bad Ref"], ["gh-hooks", "--force"], ["a", "b"]] do
      assert_raise Mix.Error, ~r/usage: mix fermix.cues.funnel|not a source name/, fn ->
        Funnel.execute(args, runner: runner(%{}))
      end
    end
  end
end
