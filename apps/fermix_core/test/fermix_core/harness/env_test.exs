defmodule FermixCore.Harness.EnvTest do
  # async: false — the secret-non-leak test mutates the daemon process environment
  # (System.put_env) and spawns a real child, so it must run serially with
  # save/restore around the shared env var (env_test.exs idiom).
  use ExUnit.Case, async: false

  alias FermixCore.CommandRunner
  alias FermixCore.Harness.Env

  @secret_name "FERMIX_TEST_SECRET"
  @path "/usr/bin:/bin"

  setup do
    original = System.get_env(@secret_name)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(@secret_name)
        value -> System.put_env(@secret_name, value)
      end
    end)

    :ok
  end

  describe "build/4 shape" do
    test "produces env -i with the reserved identity set, sorted extras, then binary and argv" do
      assert {:ok, %{executable: "/usr/bin/env", args: args}} =
               Env.build("/opt/vendor/cli", ["exec", "--json"], %{"B" => "2", "A" => "1"},
                 home: "/home/op",
                 path: "/usr/bin:/bin",
                 user: "op"
               )

      assert args == [
               "-i",
               "HOME=/home/op",
               "PATH=/usr/bin:/bin",
               "TERM=xterm-256color",
               "USER=op",
               "A=1",
               "B=2",
               "/opt/vendor/cli",
               "exec",
               "--json"
             ]
    end

    test "an empty allowed_env yields just the reserved identity set before the binary" do
      assert {:ok, %{args: args}} =
               Env.build("/opt/vendor/cli", [], %{}, home: "/h", path: "/p", user: "op")

      assert args == [
               "-i",
               "HOME=/h",
               "PATH=/p",
               "TERM=xterm-256color",
               "USER=op",
               "/opt/vendor/cli"
             ]
    end
  end

  describe "build/4 refusals" do
    test "a relative vendor binary is refused" do
      assert {:error, :relative_binary} =
               Env.build("cli", [], %{}, home: "/h", path: "/p", user: "op")
    end

    test "a reserved name in allowed_env is refused" do
      for name <- ["HOME", "PATH", "TERM", "USER"] do
        assert {:error, {:reserved_env, ^name}} =
                 Env.build("/opt/cli", [], %{name => "x"}, home: "/h", path: "/p", user: "op")
      end
    end

    test "an env name carrying '=' cannot smuggle a reserved override" do
      # "PATH=/evil" is not a legal env-var name; without name validation it would
      # assemble to `PATH=/evil=x`, which `env` reads as PATH=`/evil=x`, defeating
      # the exact-string reserved check and overriding the reserved PATH.
      assert {:error, {:invalid_env_name, "PATH=/evil"}} =
               Env.build("/opt/cli", [], %{"PATH=/evil" => "x"},
                 home: "/h",
                 path: "/p",
                 user: "op"
               )
    end

    test "an empty or otherwise malformed env name is refused" do
      for bad <- ["", "1LEADS_WITH_DIGIT", "has space", "has-dash"] do
        assert {:error, {:invalid_env_name, ^bad}} =
                 Env.build("/opt/cli", [], %{bad => "v"}, home: "/h", path: "/p", user: "op")
      end
    end

    # A daemon with no USER cannot authenticate a keychain-backed vendor, so the
    # run is refused here rather than spawned into an opaque "Not logged in".
    test "a missing home, path, or user option is refused" do
      assert {:error, {:missing_opt, :home}} =
               Env.build("/opt/cli", [], %{}, path: "/p", user: "op")

      assert {:error, {:missing_opt, :path}} =
               Env.build("/opt/cli", [], %{}, home: "/h", user: "op")

      assert {:error, {:missing_opt, :user}} =
               Env.build("/opt/cli", [], %{}, home: "/h", path: "/p")

      assert {:error, {:missing_opt, :home}} =
               Env.build("/opt/cli", [], %{}, home: "", path: "/p", user: "op")

      assert {:error, {:missing_opt, :user}} =
               Env.build("/opt/cli", [], %{}, home: "/h", path: "/p", user: "")
    end
  end

  describe "secret non-leak (§6.2 P0 gate)" do
    test "a daemon-env secret never reaches the spawned child (no Port :env overlay)" do
      System.put_env(@secret_name, "leaked-if-present")
      home = FermixTestSupport.SafeRm.make_tmp_dir!("harness-env-home")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)

      # vendor_binary = /usr/bin/env with no argv: the child prints its own
      # environment to stdout — exactly the environment `env -i` reconstructed.
      assert {:ok, %{executable: exe, args: args}} =
               Env.build("/usr/bin/env", [], %{}, home: home, path: @path, user: "op")

      assert {:ok, %{exit: 0, stdout: dump}} =
               CommandRunner.run(exe, args, supervised: false, timeout_ms: 10_000)

      refute dump =~ @secret_name
      refute dump =~ "leaked-if-present"
      assert dump =~ "HOME=#{home}"
      assert dump =~ "PATH=#{@path}"
      assert dump =~ "TERM=xterm-256color"

      # The fidelity half of the same gate. Everything above asserts what the child
      # must NOT receive; a wiped environment can be perfectly clean and still
      # unusable. With USER stripped, Claude Code resolved the macOS Keychain
      # account "unknown", found no OAuth token, and every run died in ~2s with
      # "Not logged in · Please run /login" — invisible to `mix test`, because the
      # stub CLIs the run tests use need no identity at all.
      assert dump =~ "USER=op"
    end
  end
end
