defmodule FermixCore.Release.PackagedMuslRuntimeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias FermixCore.Release.PackagedMuslRuntime

  @digest "6b558025200a5ed1308e2ce2675217afec71b6c5a9d561e52262ca948d59905e"

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("packaged-musl")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    self_dir = Path.join(root, "burrito")
    File.mkdir_p!(Path.join(self_dir, "src"))

    %{root: root, self_dir: self_dir}
  end

  describe "rewrite_env!/1" do
    test "replaces Burrito's /tmp loader address with the address the package owns" do
      env = [
        {"__BURRITO_MUSL_RUNTIME_PATH", "/tmp/libc-musl-#{@digest}.so"},
        {"SOMETHING_ELSE", "kept"}
      ]

      assert {rewritten, @digest} = PackagedMuslRuntime.rewrite_env!(env)

      assert rewritten == [
               {"__BURRITO_MUSL_RUNTIME_PATH",
                "/var/lib/fermix/runtimes/#{@digest}/libc-musl.so"},
               {"SOMETHING_ELSE", "kept"}
             ]
    end

    test "refuses a build whose loader address Burrito never published" do
      assert_raise RuntimeError, ~r/__BURRITO_MUSL_RUNTIME_PATH/, fn ->
        PackagedMuslRuntime.rewrite_env!([{"SOMETHING_ELSE", "kept"}])
      end
    end

    test "refuses a loader address that does not name a digest" do
      env = [{"__BURRITO_MUSL_RUNTIME_PATH", "/tmp/libc-musl.so"}]

      assert_raise RuntimeError, ~r|/tmp/libc-musl.so|, fn ->
        PackagedMuslRuntime.rewrite_env!(env)
      end
    end
  end

  describe "run/2" do
    test "publishes the fetched loader for the package to carry", context do
      loader = "loader bytes"
      digest = :sha256 |> :crypto.hash(loader) |> Base.encode16(case: :lower)
      File.write!(Path.join([context.self_dir, "src", "musl-runtime.so"]), loader)

      {result, log} =
        with_io(fn ->
          PackagedMuslRuntime.run(fake_context(context.self_dir, digest), context.root)
        end)

      assert log =~ "packaged musl loader published to"

      published =
        Path.join([context.root, "packaging/linux/out/linux_aarch64", "libc-musl-#{digest}.so"])

      assert File.read!(published) == loader

      assert result.extra_build_env == [
               {"__BURRITO_MUSL_RUNTIME_PATH", "/var/lib/fermix/runtimes/#{digest}/libc-musl.so"}
             ]

      assert result.work_dir == "untouched"
    end

    test "refuses a loader whose bytes are not the digest Burrito's own path names", context do
      File.write!(Path.join([context.self_dir, "src", "musl-runtime.so"]), "different bytes")

      assert_raise RuntimeError, ~r/digest/, fn ->
        PackagedMuslRuntime.run(fake_context(context.self_dir, @digest), context.root)
      end

      refute File.exists?(Path.join(context.root, "packaging"))
    end

    test "refuses a build that fetched no loader at all", context do
      assert_raise RuntimeError, ~r/musl-runtime\.so/, fn ->
        PackagedMuslRuntime.run(fake_context(context.self_dir, @digest), context.root)
      end
    end

    test "refuses a target this release does not build", context do
      windows = put_in(fake_context(context.self_dir, @digest).target.os, :windows)

      assert_raise RuntimeError, ~r/Linux/, fn ->
        PackagedMuslRuntime.run(windows, context.root)
      end
    end
  end

  defp fake_context(self_dir, digest) do
    %{
      target: %{os: :linux, cpu: :aarch64, alias: :linux_aarch64},
      self_dir: self_dir,
      work_dir: "untouched",
      extra_build_env: [{"__BURRITO_MUSL_RUNTIME_PATH", "/tmp/libc-musl-#{digest}.so"}]
    }
  end
end
