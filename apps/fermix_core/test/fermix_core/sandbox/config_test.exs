defmodule FermixCore.Sandbox.ConfigTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Setup.ConfigStore

  setup do
    sandbox = Application.get_env(:fermix_core, :sandbox)
    fermix_home = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      restore_sandbox(sandbox)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    :ok
  end

  test "defaults to developer mode with workspace under FERMIX_HOME" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-config")
    System.put_env("FERMIX_HOME", home)

    config = Config.default()

    assert config.mode == :standard
    assert config.workspace_root == Path.join(home, "workspace")
    assert config.env.mode == :selected
    assert config.commands.profile == :bare
  end

  test "an empty FERMIX_HOME falls back to the default home, not a cwd-relative path" do
    System.put_env("FERMIX_HOME", "")

    config = Config.default()

    default_home = Path.join(System.user_home!(), ".fermix")
    assert config.home == default_home
    assert config.workspace_root == Path.join(default_home, "workspace")
    assert Path.type(config.workspace_root) == :absolute
  end

  test "normalizes top-level sandbox config from maps and keywords" do
    config =
      Config.normalize(%{
        "mode" => "strict",
        "workspace_root" => "~/workbox",
        "allowed_roots" => ["~/projects/app"],
        "blocked_roots" => ["~/projects/app/tmp"],
        "env" => %{
          "mode" => "selected",
          "allow" => ["OPENAI_API_KEY"],
          "OPENAI_API_KEY" => %{
            "source" => "command",
            "command" => "secret",
            "args" => ["OPENAI_API_KEY"],
            "timeout_ms" => 1000
          }
        },
        "commands" => %{
          "profile" => "assistant",
          "presets" => ["ai_tools"],
          "codex" => %{
            "enabled" => true,
            "command" => "codex",
            "args" => ["--quiet"],
            "pass_env" => ["OPENAI_API_KEY"],
            "timeout_ms" => 10_000
          }
        }
      })

    assert config.mode == :strict
    assert config.workspace_root == Path.expand("~/workbox")
    assert config.allowed_roots == [Path.expand("~/projects/app")]
    assert config.blocked_roots == [Path.expand("~/projects/app/tmp")]
    assert config.env.allow == ["OPENAI_API_KEY"]
    assert config.env.sources["OPENAI_API_KEY"].source == :command
    assert config.commands.profile == :assistant
    assert config.commands.presets == ["ai_tools"]
    assert config.commands.explicit["codex"].enabled == true
    assert config.commands.explicit["codex"].command == "codex"
    assert config.commands.explicit["codex"].args == ["--quiet"]
    assert config.commands.explicit["codex"].pass_env == ["OPENAI_API_KEY"]
  end

  test "ConfigStore round-trips sandbox sections" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-config")
    System.put_env("FERMIX_HOME", home)

    snapshot = %{
      sandbox: [
        mode: :strict,
        workspace_root: Path.join(home, "workspace"),
        allowed_roots: [Path.join(home, "project")],
        env: [
          mode: :selected,
          allow: ["OPENAI_API_KEY"],
          sources: %{
            "OPENAI_API_KEY" => [
              source: :env,
              name: "OPENAI_API_KEY"
            ]
          }
        ],
        commands: [
          profile: :assistant,
          presets: ["ai_tools"],
          explicit: %{
            "codex" => [
              enabled: true,
              command: "codex",
              args: ["--quiet"],
              pass_env: ["OPENAI_API_KEY"]
            ]
          }
        ]
      ],
      fermix_core: [providers: [openai: []], agent: [name: "fermix"]],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)
    contents = File.read!(ConfigStore.path())

    assert contents =~ "[sandbox]"
    assert contents =~ ~s(mode = "strict")
    assert contents =~ "[sandbox.env]"
    assert contents =~ ~s(allow = ["OPENAI_API_KEY"])
    assert contents =~ "[sandbox.env.OPENAI_API_KEY]"
    assert contents =~ ~s(source = "env")
    assert contents =~ "[sandbox.commands.codex]"
    assert contents =~ ~s(command = "codex")
    assert contents =~ ~s(pass_env = ["OPENAI_API_KEY"])

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    sandbox = Config.normalize(loaded.sandbox)

    assert sandbox.mode == :strict
    assert sandbox.env.allow == ["OPENAI_API_KEY"]
    assert sandbox.env.sources["OPENAI_API_KEY"].source == :env
    assert sandbox.commands.profile == :assistant
    assert sandbox.commands.explicit["codex"].enabled == true
    assert sandbox.commands.explicit["codex"].pass_env == ["OPENAI_API_KEY"]
  end

  test "ensure_workspace creates sandbox workspace and grants dirs" do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-config")
    System.put_env("FERMIX_HOME", home)

    assert :ok = ConfigStore.ensure_workspace()
    assert File.dir?(Path.join(home, "workspace"))
    assert File.dir?(Path.join(home, "grants"))
  end

  test "normalize is idempotent over an already-normalized struct" do
    raw = %{
      "mode" => "strict",
      "workspace_root" => "~/workbox",
      "allowed_roots" => ["~/projects/app"],
      "env" => %{"mode" => "selected", "allow" => ["OPENAI_API_KEY"]},
      "commands" => %{"profile" => "assistant", "presets" => ["ai_tools"]}
    }

    once = Config.normalize(raw)

    # normalize(normalize(x)) == normalize(x): a second pass changes nothing.
    # normalize/1 re-runs over a struct (a struct is also a map) so that a
    # %Config{} carrying not-yet-normalized env sources is still fully
    # normalized by the to_keyword/persistence path.
    assert Config.normalize(once) == once
  end

  test "old mode names fail with exact migration guidance" do
    error =
      assert_raise ArgumentError, fn ->
        Config.normalize(mode: "developer")
      end

    assert Exception.message(error) =~ "developer -> standard"
    assert Exception.message(error) =~ "Run: fermix sandbox mode standard"
  end

  test "old command profile names fail with exact migration guidance" do
    error =
      assert_raise ArgumentError, fn ->
        Config.normalize(commands: [profile: "trusted"])
      end

    assert Exception.message(error) =~ "trusted -> extended"
    assert Exception.message(error) =~ "Run: fermix sandbox commands profile extended"
  end

  defp restore_sandbox(nil), do: Application.delete_env(:fermix_core, :sandbox)
  defp restore_sandbox(value), do: Application.put_env(:fermix_core, :sandbox, value)
end
