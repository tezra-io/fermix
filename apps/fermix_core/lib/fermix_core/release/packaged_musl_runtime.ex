defmodule FermixCore.Release.PackagedMuslRuntime do
  @moduledoc """
  The Burrito fetch post-step that gives the Linux package its own loader
  address (M38 §1.3, §2.2).

  Burrito's own fetch step downloads the musl loader the precompiled ERTS was
  linked against and tells the wrapper to write it to `/tmp/libc-musl-<digest>.so`
  on first launch. A packaged engine cannot use that address: `/tmp` is
  world-writable, it is `noexec` on hardened hosts, and a file already sitting
  there is trusted after a single `stat`. The package owns the loader instead,
  at `/var/lib/fermix/runtimes/<digest>/libc-musl.so`, root-owned and
  materialised by the package's own configuration step.

  This step does the two things that make that the real address:

    1. it rewrites Burrito's `__BURRITO_MUSL_RUNTIME_PATH` build variable, so
       the wrapper writes nothing into `/tmp`, and
    2. it publishes the loader Burrito just fetched to
       `packaging/linux/out/<target>/libc-musl-<digest>.so`, so the package
       build ships exactly those bytes.

  The digest is read back out of Burrito's own entry rather than kept here a
  second time: one constant in two repositories is one constant that drifts.
  The published bytes are hashed and refused when they disagree with it, so a
  loader that is not the one the ERTS was linked against never reaches a
  package.

  `FermixCore.Release.PackagedInterpreter` is the other half of the address:
  every ELF interpreter inside the payload names the same file.

  Burrito is a dependency of the umbrella root rather than of this app, so
  nothing here names a `Burrito.*` module. `execute/1` is Burrito's step
  contract and the build context is matched as the plain map it is.
  """

  @env_key "__BURRITO_MUSL_RUNTIME_PATH"
  @trusted_store "/var/lib/fermix/runtimes"
  @loader_name "libc-musl.so"
  @payload_pattern ~r/^libc-musl-([0-9a-f]{64})\.so$/
  @digest_pattern ~r/^[0-9a-f]{64}$/
  @output_prefix "packaging/linux/out"

  @doc "Burrito's step entry point, run after the fetch phase."
  @spec execute(map()) :: map()
  def execute(context) when is_map(context), do: run(context, File.cwd!())

  @doc """
  The step, with the tree it publishes into named explicitly.

  `output_root` is the checkout the release is being built from; the loader
  lands under its `packaging/linux/out/<target>/`, which is where the package
  build script collects it.
  """
  @spec run(map(), Path.t()) :: map()
  def run(%{target: %{os: :linux}} = context, output_root) when is_binary(output_root) do
    %{
      target: %{alias: target},
      self_dir: self_dir,
      extra_build_env: env
    } = context

    {rewritten, digest} = rewrite_env!(env)
    published = publish_loader!(self_dir, output_root, target, digest)

    IO.puts("fermix: packaged musl loader published to #{published}")

    %{context | extra_build_env: rewritten}
  end

  def run(%{target: %{os: os}}, output_root) when is_binary(output_root) do
    raise "fermix_linux_package builds Linux targets only, and this build asked for #{inspect(os)}"
  end

  @doc "The trusted address one loader digest is installed at."
  @spec trusted_path(String.t()) :: Path.t()
  def trusted_path(digest) when is_binary(digest) do
    Path.join([@trusted_store, digest, @loader_name])
  end

  @doc """
  Burrito's build environment with the loader address the package owns, and
  the loader digest it names.
  """
  @spec rewrite_env!([{String.t(), String.t()}]) :: {[{String.t(), String.t()}], String.t()}
  def rewrite_env!(env) when is_list(env) do
    digest = digest!(env)

    rewritten =
      Enum.map(env, fn
        {@env_key, _burrito_tmp_path} -> {@env_key, trusted_path(digest)}
        entry -> entry
      end)

    {rewritten, digest}
  end

  @doc """
  The loader digest a payload address names.

  That is Burrito's own `/tmp/libc-musl-<digest>.so` spelling, which is also
  the name the package carries the loader under before its configuration step
  materialises it.
  """
  @spec payload_digest(String.t()) :: {:ok, String.t()} | :error
  def payload_digest(path) when is_binary(path) do
    case Regex.run(@payload_pattern, Path.basename(path)) do
      [_whole, digest] -> {:ok, digest}
      nil -> :error
    end
  end

  @doc "The loader digest a trusted address (`#{@trusted_store}/<digest>/#{@loader_name}`) names."
  @spec trusted_digest(String.t()) :: {:ok, String.t()} | :error
  def trusted_digest(path) when is_binary(path) do
    digest = path |> Path.dirname() |> Path.basename()

    if Path.basename(path) == @loader_name and Regex.match?(@digest_pattern, digest) do
      {:ok, digest}
    else
      :error
    end
  end

  defp digest!(env) do
    case List.keyfind(env, @env_key, 0) do
      {@env_key, path} -> digest_from_path!(path)
      nil -> raise "Burrito published no #{@env_key}: this step must run after its fetch phase"
    end
  end

  defp digest_from_path!(path) do
    case payload_digest(path) do
      {:ok, digest} -> digest
      :error -> raise "Burrito's loader address #{path} does not name a sha256 digest"
    end
  end

  defp publish_loader!(self_dir, output_root, target, digest) do
    source = Path.join([self_dir, "src", "musl-runtime.so"])
    bytes = read_loader!(source)
    verify_digest!(source, bytes, digest)

    destination =
      Path.join([
        output_root,
        @output_prefix,
        to_string(target),
        "libc-musl-#{digest}.so"
      ])

    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, bytes)
    destination
  end

  defp read_loader!(source) do
    case File.read(source) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise "cannot read the fetched loader #{source}: #{inspect(reason)}"
    end
  end

  defp verify_digest!(source, bytes, digest) do
    actual = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    if actual != digest do
      raise "the fetched loader #{source} has digest #{actual}, and Burrito's address names #{digest}"
    end

    :ok
  end
end
