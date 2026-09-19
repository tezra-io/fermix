defmodule FermixCore.Release.PackagedInterpreterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias FermixCore.Release.PackagedInterpreter

  @digest "6b558025200a5ed1308e2ce2675217afec71b6c5a9d561e52262ca948d59905e"
  @trusted "/var/lib/fermix/runtimes/#{@digest}/libc-musl.so"
  @burrito_tmp "/tmp/libc-musl-#{@digest}.so"

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("packaged-interp")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    work_dir = Path.join(root, "work")
    File.mkdir_p!(Path.join(work_dir, "erts-16.3/bin"))
    File.mkdir_p!(Path.join(work_dir, "lib/fermix_nif-0.1.0/priv"))

    %{root: root, work_dir: work_dir}
  end

  describe "interpreter/1" do
    test "reads the interpreter one ELF executable names", context do
      path = elf!(context.work_dir, "erts-16.3/bin/beam.smp", @burrito_tmp)

      assert PackagedInterpreter.interpreter(path) == {:ok, @burrito_tmp}
    end

    test "a shared object and a plain file name no interpreter at all", context do
      shared = elf!(context.work_dir, "lib/fermix_nif-0.1.0/priv/fermix_nif.so", nil)
      beam = Path.join(context.work_dir, "lib/fermix_nif-0.1.0/priv/notes.txt")
      File.write!(beam, "not an ELF file at all")

      assert PackagedInterpreter.interpreter(shared) == :none
      assert PackagedInterpreter.interpreter(beam) == :none
    end

    test "refuses an ELF this release cannot have produced", context do
      path = Path.join(context.work_dir, "erts-16.3/bin/odd")
      File.write!(path, <<0x7F, "ELF", 1, 1, 1, 0, 0, 0::size(56)>> <> <<0::size(384)>>)

      assert_raise RuntimeError, ~r/64-bit little-endian/, fn ->
        PackagedInterpreter.interpreter(path)
      end
    end
  end

  describe "run/2" do
    test "points every packaged interpreter at the address the package owns", context do
      beam = elf!(context.work_dir, "erts-16.3/bin/beam.smp", @burrito_tmp)
      erlexec = elf!(context.work_dir, "erts-16.3/bin/erlexec", @burrito_tmp)
      shared = elf!(context.work_dir, "lib/fermix_nif-0.1.0/priv/fermix_nif.so", nil)

      {:ok, calls} = Agent.start_link(fn -> [] end)

      log =
        capture_io(fn ->
          PackagedInterpreter.run(fake_context(context.work_dir), patchelf: patcher(calls))
        end)

      assert log =~ "2 of 2 packaged interpreters now name #{@trusted}"
      assert PackagedInterpreter.interpreter(beam) == {:ok, @trusted}
      assert PackagedInterpreter.interpreter(erlexec) == {:ok, @trusted}
      assert PackagedInterpreter.interpreter(shared) == :none

      assert Enum.sort(Agent.get(calls, & &1)) == Enum.sort([beam, erlexec])
    end

    test "leaves an already trusted interpreter alone", context do
      elf!(context.work_dir, "erts-16.3/bin/beam.smp", @trusted)
      {:ok, calls} = Agent.start_link(fn -> [] end)

      capture_io(fn ->
        PackagedInterpreter.run(fake_context(context.work_dir), patchelf: patcher(calls))
      end)

      assert Agent.get(calls, & &1) == []
    end

    test "refuses an interpreter this build never named", context do
      elf!(context.work_dir, "erts-16.3/bin/beam.smp", "/lib/ld-linux-aarch64.so.1")
      {:ok, calls} = Agent.start_link(fn -> [] end)

      assert_raise RuntimeError, ~r|/lib/ld-linux-aarch64\.so\.1|, fn ->
        PackagedInterpreter.run(fake_context(context.work_dir), patchelf: patcher(calls))
      end

      assert Agent.get(calls, & &1) == []
    end

    test "refuses a loader digest that is not the one this build fetched", context do
      other = String.duplicate("a", 64)
      elf!(context.work_dir, "erts-16.3/bin/beam.smp", "/tmp/libc-musl-#{other}.so")

      assert_raise RuntimeError, ~r/#{other}/, fn ->
        PackagedInterpreter.run(fake_context(context.work_dir),
          patchelf: fn _i, _p -> {"", 0} end
        )
      end
    end

    test "refuses a patch that did not take", context do
      elf!(context.work_dir, "erts-16.3/bin/beam.smp", @burrito_tmp)

      assert_raise RuntimeError, ~r/still names/, fn ->
        PackagedInterpreter.run(fake_context(context.work_dir),
          patchelf: fn _i, _p -> {"", 0} end
        )
      end
    end

    test "refuses when patchelf itself refuses, and says what it said", context do
      elf!(context.work_dir, "erts-16.3/bin/beam.smp", @burrito_tmp)

      failing = fn _interpreter, _path -> {"cannot find section .interp", 1} end

      assert_raise RuntimeError, ~r/cannot find section \.interp/, fn ->
        PackagedInterpreter.run(fake_context(context.work_dir), patchelf: failing)
      end
    end

    test "refuses a build with no patchelf on the host", context do
      elf!(context.work_dir, "erts-16.3/bin/beam.smp", @burrito_tmp)

      assert_raise RuntimeError, ~r/patchelf/, fn ->
        PackagedInterpreter.run(fake_context(context.work_dir),
          find_executable: fn _name -> nil end
        )
      end
    end
  end

  # A patcher that does what `patchelf --set-interpreter` does to the fixture:
  # rewrites the file with the new interpreter, and records the file it saw.
  defp patcher(calls) do
    fn interpreter, path ->
      Agent.update(calls, &[path | &1])
      File.write!(path, elf_bytes(interpreter))
      {"", 0}
    end
  end

  defp fake_context(work_dir) do
    %{
      target: %{os: :linux, cpu: :aarch64, alias: :linux_aarch64},
      work_dir: work_dir,
      extra_build_env: [{"__BURRITO_MUSL_RUNTIME_PATH", @trusted}]
    }
  end

  defp elf!(work_dir, relative, interpreter) do
    path = Path.join(work_dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, elf_bytes(interpreter))
    path
  end

  # A 64-bit little-endian ELF with one program header: PT_INTERP when an
  # interpreter is named, PT_LOAD when it is not.
  defp elf_bytes(interpreter) do
    {type, body} =
      case interpreter do
        nil -> {1, ""}
        path -> {3, path <> <<0>>}
      end

    header =
      <<0x7F, "ELF", 2, 1, 1, 0, 0, 0::size(56), 2::little-16, 0xB7::little-16, 1::little-32,
        0::little-64, 64::little-64, 0::little-64, 0::little-32, 64::little-16, 56::little-16,
        1::little-16, 64::little-16, 0::little-16, 0::little-16>>

    program_header =
      <<type::little-32, 4::little-32, 120::little-64, 0::little-64, 0::little-64,
        byte_size(body)::little-64, byte_size(body)::little-64, 1::little-64>>

    header <> program_header <> body
  end
end
