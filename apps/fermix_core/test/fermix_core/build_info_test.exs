defmodule FermixCore.BuildInfoTest do
  use ExUnit.Case, async: false

  alias FermixCore.BuildInfo
  alias FermixCore.Management.Protocol, as: ManagementProtocol
  alias FermixCore.Realtime.Protocol, as: RealtimeProtocol

  @build_env_vars ~w(
    FERMIX_BUILD_ID
    FERMIX_BUILD_SOURCE_COMMIT
    FERMIX_BUILD_DISTRIBUTION
    FERMIX_BUILD_TARGET
  )

  test "exposes one immutable artifact identity" do
    identity = BuildInfo.identity()

    assert Map.keys(identity) |> Enum.sort() ==
             ~w(
               architecture artifact_target build_id distribution_identity engine_id
               product_version source_commit
             )a
             |> Enum.sort()

    assert identity.engine_id == "fermix-core"
    assert identity.product_version == to_string(Application.spec(:fermix_core, :vsn))
    assert identity.distribution_identity == "standalone"
    assert identity.build_id == nil
    assert identity.source_commit == nil
    assert identity.artifact_target == nil
    assert is_binary(identity.architecture)
    assert identity.architecture != ""
    refute BuildInfo.app_engine?()
  end

  test "runtime environment changes cannot alter compiled identity" do
    before = BuildInfo.identity()
    restore = capture_env(@build_env_vars)
    on_exit(restore)

    System.put_env("FERMIX_BUILD_ID", "runtime-build")
    System.put_env("FERMIX_BUILD_SOURCE_COMMIT", String.duplicate("a", 40))
    System.put_env("FERMIX_BUILD_DISTRIBUTION", "macos_app")
    System.put_env("FERMIX_BUILD_TARGET", "macos_aarch64")

    assert BuildInfo.identity() == before
  end

  test "the recompile hook fires exactly when the build inputs change" do
    restore = capture_env(@build_env_vars)
    on_exit(restore)

    # The suite compiles with no inherited build inputs, so the current
    # environment agrees with the compiled literals and the module is stable.
    refute BuildInfo.__mix_recompile__?()

    System.put_env("FERMIX_BUILD_ID", "recompile-probe")
    assert BuildInfo.__mix_recompile__?()
  end

  test "test compilation ignores inherited app-engine build inputs" do
    root = Path.expand("../../../..", __DIR__)

    script = """
    :code.purge(FermixCore.BuildInfo)
    :code.delete(FermixCore.BuildInfo)
    Code.compile_file("apps/fermix_core/lib/fermix_core/build_info.ex")
    IO.puts(FermixCore.BuildInfo.distribution_identity())
    """

    env = [
      {"MIX_ENV", "test"},
      {"FERMIX_BUILD_ID", "inherited-test-build"},
      {"FERMIX_BUILD_SOURCE_COMMIT", String.duplicate("b", 40)},
      {"FERMIX_BUILD_DISTRIBUTION", "macos_app"},
      {"FERMIX_BUILD_TARGET", "macos_x86_64"}
    ]

    assert {output, 0} =
             System.cmd("mix", ["run", "--no-compile", "--no-start", "-e", script],
               cd: root,
               env: env,
               stderr_to_stdout: true
             )

    assert output |> String.split() |> List.last() == "standalone"
  end

  test "publishes management and Realtime protocol ranges from their authorities" do
    assert BuildInfo.protocols() == %{
             management: protocol_metadata(ManagementProtocol),
             realtime: protocol_metadata(RealtimeProtocol)
           }
  end

  test "validates complete arm64 and x86_64 app-engine identities" do
    for {target, architecture} <- [
          {"macos_aarch64", "arm64"},
          {"macos_x86_64", "x86_64"}
        ] do
      assert :ok =
               BuildInfo.validate_app_engine(%{
                 engine_id: "fermix-core",
                 product_version: "1.2.3",
                 build_id: "release-123-attempt-1",
                 source_commit: String.duplicate("a", 40),
                 distribution_identity: "macos_app",
                 artifact_target: target,
                 architecture: architecture
               })
    end
  end

  test "rejects incomplete or contradictory app-engine identities" do
    valid = %{
      engine_id: "fermix-core",
      product_version: "1.2.3",
      build_id: "release-123-attempt-1",
      source_commit: String.duplicate("a", 40),
      distribution_identity: "macos_app",
      artifact_target: "macos_aarch64",
      architecture: "arm64"
    }

    assert {:error, {:invalid_build_info, :build_id}} =
             BuildInfo.validate_app_engine(%{valid | build_id: nil})

    assert {:error, {:invalid_build_info, :source_commit}} =
             BuildInfo.validate_app_engine(%{valid | source_commit: "short"})

    assert {:error, {:invalid_build_info, :distribution_identity}} =
             BuildInfo.validate_app_engine(%{valid | distribution_identity: "standalone"})

    assert {:error, {:invalid_build_info, :artifact_target}} =
             BuildInfo.validate_app_engine(%{valid | artifact_target: "linux_aarch64"})

    assert {:error, {:invalid_build_info, :architecture}} =
             BuildInfo.validate_app_engine(%{valid | architecture: "x86_64"})
  end

  defp protocol_metadata(module) do
    {minimum, maximum} = module.supported_version_range()

    %{
      current_version: module.protocol_version(),
      minimum_version: minimum,
      maximum_version: maximum
    }
  end

  defp capture_env(names) do
    values = Map.new(names, &{&1, System.get_env(&1)})

    fn ->
      Enum.each(values, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
