defmodule FermixCore.Release.PackagedInterpreter do
  @moduledoc """
  The Burrito patch post-step that points every packaged ELF interpreter at the
  loader the package owns (M38 §1.3, "Build integration").

  The precompiled musl ERTS is linked against `/tmp/libc-musl-<digest>.so`:
  that address is written into the `PT_INTERP` segment of `beam.smp`,
  `erlexec`, `erl_child_setup` and every other ERTS executable, and it is what
  the kernel opens before the process runs. Rewriting Burrito's build variable
  alone (`FermixCore.Release.PackagedMuslRuntime`) stops the wrapper from
  *writing* into `/tmp` and changes nothing about where those binaries *look*,
  so a package built without this step launches nothing at all on a host with
  an empty `/tmp`.

  This step therefore rewrites the interpreter of every ELF executable in the
  payload to the address the package materialises, and proves the rewrite: a
  file whose interpreter is neither this build's `/tmp` loader nor the trusted
  address already refuses the build by name, and a patch that did not take is
  an error rather than a silently unpatched binary. Shared objects and BEAM
  files name no interpreter and are left alone.

  `patchelf` does the rewrite because the trusted address is longer than the
  address it replaces, so the program headers move; it is injectable, and its
  absence is a named refusal rather than a skipped step.

  Burrito is a dependency of the umbrella root rather than of this app, so
  nothing here names a `Burrito.*` module. `execute/1` is Burrito's step
  contract and the build context is matched as the plain map it is.
  """

  alias FermixCore.Release.PackagedMuslRuntime

  @env_key "__BURRITO_MUSL_RUNTIME_PATH"
  @elf_magic <<0x7F, "ELF">>
  @elf_header_bytes 64
  @pt_interp 3
  @burrito_tmp_pattern ~r|^/tmp/libc-musl-[0-9a-f]{64}\.so$|

  @doc "Burrito's step entry point, run after the patch phase."
  @spec execute(map()) :: map()
  def execute(context) when is_map(context), do: run(context, [])

  @doc """
  The step, with `patchelf` and its lookup injectable.

  `:patchelf` is a two-argument runner `(interpreter, path)` returning
  `{output, status}`; `:find_executable` resolves the tool.
  """
  @spec run(map(), keyword()) :: map()
  def run(%{target: %{os: :linux}} = context, opts) when is_list(opts) do
    %{work_dir: work_dir, extra_build_env: env} = context

    trusted = trusted_path!(env)
    digest = digest!(trusted)
    targets = payload_interpreters(work_dir)
    pending = Enum.reject(targets, fn {_path, interpreter} -> interpreter == trusted end)

    Enum.each(pending, fn {path, interpreter} ->
      refuse_unknown_interpreter!(path, interpreter, digest)
    end)

    patchelf = patchelf!(opts)
    Enum.each(pending, fn {path, _interpreter} -> patch!(path, trusted, patchelf) end)

    IO.puts(
      "fermix: #{length(pending)} of #{length(targets)} packaged interpreters now name #{trusted}"
    )

    context
  end

  def run(%{target: %{os: os}}, opts) when is_list(opts) do
    raise "fermix_linux_package builds Linux targets only, and this build asked for #{inspect(os)}"
  end

  @doc """
  The interpreter one file names, if it is a 64-bit ELF that names one.

  A file that is not an ELF at all, and an ELF with no `PT_INTERP` segment
  (every shared object, every static executable), answer `:none`. An ELF this
  release cannot have produced refuses rather than being reported as
  interpreter-free.
  """
  @spec interpreter(Path.t()) :: {:ok, String.t()} | :none
  def interpreter(path) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          read_interpreter(io, path)
        after
          File.close(io)
        end

      {:error, reason} ->
        raise "cannot inspect #{path}: #{inspect(reason)}"
    end
  end

  defp read_interpreter(io, path) do
    case :file.pread(io, 0, @elf_header_bytes) do
      {:ok, <<@elf_magic, class, data, _rest::binary>> = header} ->
        assert_supported!(path, class, data)
        interpreter_segment(io, path, header)

      _not_an_elf ->
        :none
    end
  end

  defp assert_supported!(path, class, data) do
    if {class, data} != {2, 1} do
      raise "#{path} is not a 64-bit little-endian ELF, which is all this release can carry"
    end

    :ok
  end

  defp interpreter_segment(io, path, header) do
    <<_ident::binary-size(32), phoff::little-64, _shoff::little-64, _flags::little-32,
      _ehsize::little-16, phentsize::little-16, phnum::little-16, _rest::binary>> = header

    io
    |> program_headers(path, phoff, phentsize, phnum)
    |> Enum.find_value(:none, &interp_segment(io, path, &1))
  end

  defp program_headers(_io, _path, _phoff, _phentsize, 0), do: []

  defp program_headers(io, path, phoff, phentsize, phnum) do
    case :file.pread(io, phoff, phentsize * phnum) do
      {:ok, headers} -> chunk(headers, phentsize)
      other -> raise "cannot read the program headers of #{path}: #{inspect(other)}"
    end
  end

  defp chunk(headers, phentsize) do
    for <<header::binary-size(phentsize) <- headers>>, do: header
  end

  defp interp_segment(
         io,
         path,
         <<@pt_interp::little-32, _flags::little-32, offset::little-64, _vaddr::little-64,
           _paddr::little-64, filesz::little-64, _rest::binary>>
       ) do
    case :file.pread(io, offset, filesz) do
      {:ok, raw} -> {:ok, raw |> String.trim_trailing(<<0>>) |> to_string()}
      other -> raise "cannot read the interpreter of #{path}: #{inspect(other)}"
    end
  end

  defp interp_segment(_io, _path, _other_segment), do: nil

  defp payload_interpreters(work_dir) do
    work_dir
    |> files()
    |> Enum.flat_map(fn path ->
      case interpreter(path) do
        {:ok, interpreter} -> [{path, interpreter}]
        :none -> []
      end
    end)
  end

  defp files(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp refuse_unknown_interpreter!(path, interpreter, digest) do
    unless Regex.match?(@burrito_tmp_pattern, interpreter) do
      raise "#{path} names the interpreter #{interpreter}, which this build never produced"
    end

    case PackagedMuslRuntime.payload_digest(interpreter) do
      {:ok, ^digest} ->
        :ok

      {:ok, other} ->
        raise "#{path} names loader #{other}, and this build fetched #{digest}"

      :error ->
        raise "#{path} names the interpreter #{interpreter}, which names no loader digest"
    end
  end

  defp patch!(path, trusted, patchelf) do
    case patchelf.(trusted, path) do
      {_output, 0} -> assert_patched!(path, trusted)
      {output, status} -> raise "patchelf exited #{status} on #{path}: #{String.trim(output)}"
    end
  end

  defp assert_patched!(path, trusted) do
    case interpreter(path) do
      {:ok, ^trusted} -> :ok
      {:ok, other} -> raise "#{path} still names #{other} after patchelf"
      :none -> raise "#{path} still names no interpreter after patchelf"
    end
  end

  defp trusted_path!(env) do
    case List.keyfind(env, @env_key, 0) do
      {@env_key, path} -> path
      nil -> raise "Burrito published no #{@env_key}: this step must run after its fetch phase"
    end
  end

  defp digest!(trusted) do
    case PackagedMuslRuntime.trusted_digest(trusted) do
      {:ok, digest} ->
        digest

      :error ->
        raise "the loader address #{trusted} does not name a sha256 digest, so no payload " <>
                "interpreter can be checked against it"
    end
  end

  defp patchelf!(opts) do
    case Keyword.fetch(opts, :patchelf) do
      {:ok, runner} when is_function(runner, 2) -> runner
      :error -> default_patchelf(opts)
    end
  end

  defp default_patchelf(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find.("patchelf") do
      nil ->
        raise "patchelf is required to build fermix_linux_package and was not found on PATH"

      executable ->
        fn interpreter, path ->
          System.cmd(executable, ["--set-interpreter", interpreter, path], stderr_to_stdout: true)
        end
    end
  end
end
