defmodule FermixCore.Sandbox.EnvTest do
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Env
  alias FermixCore.Tools.Shell

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    original = System.get_env("FERMIX_TEST_SECRET")

    on_exit(fn ->
      case original do
        nil -> System.delete_env("FERMIX_TEST_SECRET")
        value -> System.put_env("FERMIX_TEST_SECRET", value)
      end
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

  test "missing selected env fails clearly" do
    System.delete_env("FERMIX_TEST_SECRET")

    assert {:error, {:missing_env, "FERMIX_TEST_SECRET"}} =
             Env.build(Config.normalize(env: [allow: ["FERMIX_TEST_SECRET"]]))

    message = Env.format_error({:missing_env, "FERMIX_TEST_SECRET"})
    assert message =~ "FERMIX_TEST_SECRET could not be resolved"
    assert message =~ "fermix sandbox env set FERMIX_TEST_SECRET"
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

    assert {:ok, env} = Env.build(config)
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

    assert {:error, :env_command_output_not_single_value} = Env.build(config)
  end

  test "command env source rejects oversized helper output" do
    config =
      command_source_config(["-c", "head -c 9000 /dev/zero | tr '\\0' 'a'"], 5_000)

    assert {:error, :env_command_output_too_large} = Env.build(config)
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

    assert {:error, {:env_command_not_found, ^missing}} = Env.build(config)

    message = Env.format_error({:env_command_not_found, missing})
    assert message =~ missing
    assert message =~ "fermix sandbox env set"
  end

  test "helper timeout kills the OS child" do
    marker =
      Path.join(System.tmp_dir!(), "fermix_env_kill_#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm(marker) end)

    config = command_source_config(["-c", "sleep 0.4; touch #{marker}"], 100)

    assert {:error, {:env_command_timeout, _command, 100}} = Env.build(config)

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
