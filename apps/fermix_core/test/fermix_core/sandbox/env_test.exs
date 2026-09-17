defmodule FermixCore.Sandbox.EnvTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Env
  alias FermixCore.Tools.Shell

  @context %{agent_name: "test_agent", conversation_key: :test}
  @names ["FERMIX_TEST_SECRET", "FERMIX_TEST_ABSENT"]

  setup do
    originals = Enum.map(@names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(originals, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "shell does not inherit undeclared env values" do
    System.put_env("FERMIX_TEST_SECRET", "hidden")
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-env")
    context = context(root, [])

    assert {:ok, result} =
             Shell.execute(%{"command" => "printf \"$FERMIX_TEST_SECRET\""}, context)

    assert result.success == true
    assert result.output == ""

    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  test "shell receives selected env values" do
    System.put_env("FERMIX_TEST_SECRET", "visible")
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-env")
    config = [mode: :strict, workspace_root: root, env: [allow: ["FERMIX_TEST_SECRET"]]]

    assert {:ok, result} =
             Shell.execute(
               %{"command" => "printf \"$FERMIX_TEST_SECRET\""},
               context(root, config)
             )

    assert result.success == true
    assert result.output == "visible"

    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  # One allowed name the daemon cannot read must not refuse every command: a
  # stale entry took the shell tool down for every session for 26 days while
  # each command asked for nothing but `date`. The name is reported by name,
  # with the same remedy sentence the CLI prints, and everything else passes.
  test "an allowed name that cannot be resolved is reported and the rest still pass" do
    System.put_env("FERMIX_TEST_SECRET", "visible")
    System.delete_env("FERMIX_TEST_ABSENT")

    config = Config.normalize(env: [allow: ["FERMIX_TEST_SECRET", "FERMIX_TEST_ABSENT"]])

    assert {:ok, built} = Env.build(config)
    assert {"FERMIX_TEST_SECRET", "visible"} in built.env
    refute List.keymember?(built.env, "FERMIX_TEST_ABSENT", 0)
    assert built.resolved == ["FERMIX_TEST_SECRET"]

    assert built.unresolved == [
             %{name: "FERMIX_TEST_ABSENT", reason: {:missing_env, "FERMIX_TEST_ABSENT"}}
           ]

    message = Env.format_error({:missing_env, "FERMIX_TEST_ABSENT"})
    assert message =~ "FERMIX_TEST_ABSENT could not be resolved"
    assert message =~ "fermix sandbox env set FERMIX_TEST_ABSENT"
  end

  test "every allowed name resolving reports nothing unresolved" do
    System.put_env("FERMIX_TEST_SECRET", "visible")

    assert {:ok, built} = Env.build(Config.normalize(env: [allow: ["FERMIX_TEST_SECRET"]]))
    assert built.resolved == ["FERMIX_TEST_SECRET"]
    assert built.unresolved == []
  end

  # A consumer that names a variable it needs (a harness adapter, a command
  # capability) is not the allow list: its request is a requirement, and a
  # requirement that cannot be met is an error, never a silent omission.
  test "a name a consumer requests explicitly must resolve" do
    System.delete_env("FERMIX_TEST_ABSENT")

    assert {:error, {:missing_env, "FERMIX_TEST_ABSENT"}} =
             Env.build(Config.normalize(env: [allow: []]), ["FERMIX_TEST_ABSENT"])
  end

  test "a requested name that is also allowed is still a requirement" do
    System.delete_env("FERMIX_TEST_ABSENT")

    assert {:error, {:missing_env, "FERMIX_TEST_ABSENT"}} =
             Env.build(Config.normalize(env: [allow: ["FERMIX_TEST_ABSENT"]]), [
               "FERMIX_TEST_ABSENT"
             ])
  end

  test "a requested name that is also allowed counts as resolved once, even when listed twice" do
    System.put_env("FERMIX_TEST_SECRET", "visible")

    config =
      Config.normalize(env: [allow: ["FERMIX_TEST_SECRET", "FERMIX_TEST_SECRET"]])

    assert {:ok, built} = Env.build(config, ["FERMIX_TEST_SECRET"])
    assert {"FERMIX_TEST_SECRET", "visible"} in built.env
    assert built.resolved == ["FERMIX_TEST_SECRET"]
    assert built.unresolved == []
  end

  # `mode = "all"` is the whole daemon environment only while nothing is named;
  # denying the one allowed name narrows to the default keys and never widens.
  describe "mode all" do
    test "nothing named passes the daemon environment minus the deny list" do
      System.put_env("FERMIX_TEST_SECRET", "visible")
      System.put_env("FERMIX_TEST_ABSENT", "denied-value")

      config = Config.normalize(env: [mode: :all, deny: ["FERMIX_TEST_ABSENT"]])

      assert {:ok, built} = Env.build(config)
      assert {"FERMIX_TEST_SECRET", "visible"} in built.env
      refute List.keymember?(built.env, "FERMIX_TEST_ABSENT", 0)
      assert List.keymember?(built.env, "HOME", 0)
      assert built.resolved == []
      assert built.unresolved == []
    end

    test "denying the only allowed name leaves the default keys, never everything" do
      System.put_env("FERMIX_TEST_SECRET", "visible")
      System.put_env("FERMIX_TEST_ABSENT", "unnamed-value")

      config =
        Config.normalize(
          env: [mode: :all, allow: ["FERMIX_TEST_SECRET"], deny: ["FERMIX_TEST_SECRET"]]
        )

      assert {:ok, built} = Env.build(config)
      refute List.keymember?(built.env, "FERMIX_TEST_SECRET", 0)
      refute List.keymember?(built.env, "FERMIX_TEST_ABSENT", 0)
      assert List.keymember?(built.env, "HOME", 0)
      assert built.resolved == []
      assert built.unresolved == []
    end

    test "an allowed name resolves by name and the rest of the environment stays out" do
      System.put_env("FERMIX_TEST_SECRET", "visible")
      System.put_env("FERMIX_TEST_ABSENT", "unnamed-value")

      config = Config.normalize(env: [mode: :all, allow: ["FERMIX_TEST_SECRET"]])

      assert {:ok, built} = Env.build(config)
      assert {"FERMIX_TEST_SECRET", "visible"} in built.env
      refute List.keymember?(built.env, "FERMIX_TEST_ABSENT", 0)
      assert built.resolved == ["FERMIX_TEST_SECRET"]
    end
  end

  test "command env source reads a structured helper command" do
    config =
      Config.normalize(
        env: [
          allow: ["FERMIX_TEST_SECRET"],
          sources: %{
            "FERMIX_TEST_SECRET" => [
              source: :command,
              command: "/bin/echo",
              args: ["from-helper"]
            ]
          }
        ]
      )

    assert {:ok, built} = Env.build(config)
    assert {"FERMIX_TEST_SECRET", "from-helper"} in built.env
    assert built.unresolved == []
  end

  test "build_command/3 threads supervised: false (tree-less fermix sandbox verb)" do
    config =
      Config.normalize(
        env: [
          allow: ["FERMIX_TEST_SECRET"],
          sources: %{
            "FERMIX_TEST_SECRET" => [
              source: :command,
              command: "/bin/echo",
              args: ["from-helper"]
            ]
          }
        ]
      )

    assert {:ok, env} = Env.build_command(config, ["FERMIX_TEST_SECRET"], supervised: false)
    assert {"FERMIX_TEST_SECRET", "from-helper"} in env
  end

  test "command env source rejects multi-line helper output" do
    config =
      Config.normalize(
        env: [
          allow: ["FERMIX_TEST_SECRET"],
          sources: %{
            "FERMIX_TEST_SECRET" => [
              source: :command,
              command: "/bin/sh",
              args: ["-c", "printf 'one\\ntwo\\n'"]
            ]
          }
        ]
      )

    assert {:ok, built} = Env.build(config)

    assert built.unresolved == [
             %{name: "FERMIX_TEST_SECRET", reason: :env_command_output_not_single_value}
           ]

    refute List.keymember?(built.env, "FERMIX_TEST_SECRET", 0)

    assert {:error, :env_command_output_not_single_value} =
             Env.build_command(config, ["FERMIX_TEST_SECRET"])
  end

  test "command env source rejects oversized helper output" do
    config =
      command_source_config(["-c", "head -c 9000 /dev/zero | tr '\\0' 'a'"], 5_000)

    assert {:ok, built} = Env.build(config)

    assert built.unresolved == [
             %{name: "FERMIX_TEST_SECRET", reason: :env_command_output_too_large}
           ]

    assert {:error, :env_command_output_too_large} =
             Env.build_command(config, ["FERMIX_TEST_SECRET"])
  end

  test "missing helper executable returns an error instead of crashing" do
    missing = "/no/such/helper-#{System.unique_integer([:positive])}"

    config =
      Config.normalize(
        env: [
          allow: ["FERMIX_TEST_SECRET"],
          sources: %{
            "FERMIX_TEST_SECRET" => [source: :command, command: missing, args: []]
          }
        ]
      )

    assert {:ok, built} = Env.build(config)

    assert built.unresolved == [
             %{name: "FERMIX_TEST_SECRET", reason: {:env_command_not_found, missing}}
           ]

    assert {:error, {:env_command_not_found, ^missing}} =
             Env.build_command(config, ["FERMIX_TEST_SECRET"])

    message = Env.format_error({:env_command_not_found, missing})
    assert message =~ missing
    assert message =~ "fermix sandbox env set"
  end

  test "helper timeout kills the OS child" do
    marker =
      Path.join(System.tmp_dir!(), "fermix_env_kill_#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm(marker) end)

    config = command_source_config(["-c", "sleep 0.4; touch #{marker}"], 100)

    assert {:ok, built} = Env.build(config)

    assert [%{name: "FERMIX_TEST_SECRET", reason: {:env_command_timeout, _command, 100}}] =
             built.unresolved

    Process.sleep(800)
    refute File.exists?(marker), "helper child outlived the timeout — touch ran to completion"
  end

  defp command_source_config(args, timeout_ms) do
    sh = System.find_executable("sh") || "/bin/sh"

    Config.normalize(
      env: [
        allow: ["FERMIX_TEST_SECRET"],
        sources: %{
          "FERMIX_TEST_SECRET" => [
            source: :command,
            command: sh,
            args: args,
            timeout_ms: timeout_ms
          ]
        }
      ]
    )
  end

  test "command env build requires pass_env names to be allowed" do
    config = Config.normalize(env: [allow: []])

    assert {:error, {:env_not_allowed, "FERMIX_TEST_SECRET"}} =
             Env.build_command(config, ["FERMIX_TEST_SECRET"])

    message = Env.format_error({:env_not_allowed, "FERMIX_TEST_SECRET"})
    assert message =~ "FERMIX_TEST_SECRET is not allowed"
    assert message =~ "fermix sandbox env allow FERMIX_TEST_SECRET"
  end

  defp context(root, config) do
    config =
      config
      |> Keyword.put_new(:mode, :strict)
      |> Keyword.put_new(:workspace_root, root)

    Map.put(@context, :sandbox_config, Config.normalize(config))
  end
end
