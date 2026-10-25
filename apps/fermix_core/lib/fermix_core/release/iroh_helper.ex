defmodule FermixCore.Release.IrohHelper do
  @moduledoc """
  Puts the pinned `fermix-iroh` helper into a release tree (M62 stage 5).

  `place/3` is the one function: it puts one target's pinned helper at
  `<priv_dir>/iroh_helper/bin/fermix-iroh`, mode 0755, and the helper's
  pinned third-party notices at `<priv_dir>/iroh_helper/THIRD-PARTY-NOTICES.txt`,
  mode 0644, or raises a sentence that names the target and what failed. The
  licences of what is compiled into the helper ask for their notices to
  travel with it, so `place/3` returns only once both are in place. Each
  destination that already has its pinned digest is kept; otherwise its asset
  is fetched once from the pinned release, written to a temporary file beside
  the destination, hashed, given its mode, renamed into place and hashed again.
  There is no cache, no retry and no other source: the digests in `PIN.json`
  are what prove the files.

  `PIN.json` sits beside the protocol the helper speaks, in this app's source
  `priv`, and is written only by `scripts/release/pin_iroh_helper.py`. The
  release steps below run in the build checkout, so the compiled source path
  is the pin they read.

  The callers compute the destination:

    * every Burrito target (the formula binaries and the Linux package) runs
      `execute/1` after its patch phase, in its own `work_dir`;
    * the Mac app engine runs `place_in_release/2` between `:assemble` and its
      manifest, so the inventory lists the helper and checks its architecture;
    * a source checkout runs `mix fermix.iroh_helper`.

  Burrito is a dependency of the umbrella root rather than of this app, so
  nothing here names a `Burrito.*` module. `execute/1` is Burrito's step
  contract and the build context is matched as the plain map it is.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Net.Egress

  @source_priv Path.expand("../../../priv", __DIR__)
  @pin_path Path.join(@source_priv, "iroh_helper/PIN.json")
  @helper_path "iroh_helper/bin/fermix-iroh"
  @notices_path "iroh_helper/THIRD-PARTY-NOTICES.txt"
  @targets ~w(linux_aarch64 linux_x86_64 macos_aarch64 macos_x86_64)
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @connect_timeout_ms 15_000
  @receive_timeout_ms 60_000

  @typedoc "What `place/3` did with one file, and where."
  @type placement :: %{action: :kept | :placed, path: Path.t()}

  @typedoc """
  What `place/3` did with the helper and with its notices, and the helper
  version the pin names.
  """
  @type outcome :: %{
          action: :kept | :placed,
          path: Path.t(),
          notices: placement(),
          version: String.t()
        }

  @typedoc "A fetch: the asset's bytes, or why there are none."
  @type fetcher :: (String.t() -> {:ok, binary()} | {:error, term()})

  @doc "The source tree's `fermix_core` priv, where a checkout's helper lives."
  @spec source_priv_dir() :: Path.t()
  def source_priv_dir, do: @source_priv

  @doc "The checked-in pin the release steps read by default."
  @spec pin_path() :: Path.t()
  def pin_path, do: @pin_path

  @doc """
  Reads and checks a pin: schema 2, the release it names, the notices and
  exactly the four Burrito targets, each with an asset and a sha256 digest.
  Raises on anything else, naming the file.
  """
  @spec read_pin!(Path.t()) :: map()
  def read_pin!(path \\ @pin_path) when is_binary(path) do
    pin =
      case File.read(path) do
        {:ok, raw} -> decode_pin!(path, raw)
        {:error, reason} -> raise "cannot read the fermix-iroh pin #{path}: #{inspect(reason)}"
      end

    check_pin!(path, pin)
  end

  @doc """
  Puts `target`'s pinned helper at `<priv_dir>/iroh_helper/bin/fermix-iroh`
  and the pinned notices at `<priv_dir>/iroh_helper/THIRD-PARTY-NOTICES.txt`.

  `target` is a Burrito target alias, as an atom or as the string the
  compiled build identity carries. Options: `:pin_path` (default the checked-in
  pin) and `:fetch`, a `t:fetcher/0` (default `fetch/1`), so tests never reach
  the network.
  """
  @spec place(atom() | String.t(), Path.t(), keyword()) :: outcome()
  def place(target, priv_dir, opts \\ [])
      when (is_binary(target) or (is_atom(target) and not is_nil(target))) and
             is_binary(priv_dir) and is_list(opts) do
    pin = opts |> Keyword.get(:pin_path, @pin_path) |> read_pin!()
    fetcher = Keyword.get(opts, :fetch, &fetch/1)

    helper_file = %{
      name: "helper",
      entry: target_entry!(pin, target),
      path: Path.join(priv_dir, @helper_path),
      mode: 0o755
    }

    notices_file = %{
      name: "notices file",
      entry: pin["notices"],
      path: Path.join(priv_dir, @notices_path),
      mode: 0o644
    }

    [helper, notices] =
      Enum.map([helper_file, notices_file], &place_file!(&1, pin, target, fetcher))

    %{action: helper.action, path: helper.path, notices: notices, version: pin["version"]}
  end

  @doc """
  Fetches one asset exactly as served (`raw: true`: no decompression, no
  decoding), once. `req_options` are merged last, which is how tests serve it.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def fetch(url, req_options \\ []) when is_binary(url) and is_list(req_options) do
    # A release step runs before any application of this release is started.
    {:ok, _started} = Application.ensure_all_started(:req)

    # `:direct` sets connect options only, so it needs no pool from a started
    # application, and a build host with a `[fermix_core.network]` proxy uses it.
    request =
      [
        url: url,
        raw: true,
        retry: false,
        connect_options: [timeout: @connect_timeout_ms],
        receive_timeout: @receive_timeout_ms
      ]
      |> Keyword.merge(req_options)
      |> Req.new()
      |> Egress.attach(:direct)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc "Burrito's step entry point, run after the patch phase."
  @spec execute(map()) :: map()
  def execute(context) when is_map(context), do: run(context, [])

  @doc """
  The Burrito step, with `place/3`'s options: places the context's target in
  the one `fermix_core` priv of its `work_dir` and returns the context
  unchanged.
  """
  @spec run(map(), keyword()) :: map()
  def run(%{target: %{alias: target}, work_dir: work_dir} = context, opts)
      when is_binary(work_dir) and is_list(opts) do
    target |> place(payload_priv!(work_dir), opts) |> report(target)
    context
  end

  @doc """
  The app engine's release step: places the compiled identity's target in the
  assembled `fermix_core` priv and returns the release. `:target` overrides
  the compiled one for tests; the other options are `place/3`'s.
  """
  @spec place_in_release(map(), keyword()) :: map()
  def place_in_release(%{path: path, applications: applications} = release, opts \\ [])
      when is_binary(path) and is_map(applications) and is_list(opts) do
    target = Keyword.get_lazy(opts, :target, fn -> BuildInfo.identity().artifact_target end)
    vsn = applications |> Map.fetch!(:fermix_core) |> Keyword.fetch!(:vsn) |> to_string()
    priv = Path.join([path, "lib", "fermix_core-#{vsn}", "priv"])

    unless File.dir?(priv), do: raise("the assembled release has no #{priv}")

    target |> place(priv, Keyword.delete(opts, :target)) |> report(target)
    release
  end

  defp decode_pin!(path, raw) do
    case Jason.decode(raw) do
      {:ok, %{} = pin} ->
        pin

      {:ok, _other} ->
        raise "#{path} is not a valid fermix-iroh pin: not a JSON object"

      {:error, error} ->
        raise "#{path} is not a valid fermix-iroh pin: #{Exception.message(error)}"
    end
  end

  defp check_pin!(path, pin) do
    problem =
      cond do
        pin["schema_version"] != 2 -> "schema_version is not 2"
        not text?(pin["repository"]) -> "repository is missing"
        not text?(pin["tag"]) -> "tag is missing"
        not text?(pin["version"]) -> "version is missing"
        not is_map(pin["targets"]) -> "targets is missing"
        Enum.sort(Map.keys(pin["targets"])) != @targets -> "targets are not #{names(@targets)}"
        true -> pin |> entries() |> Enum.find_value(&entry_problem/1)
      end

    if problem, do: raise("#{path} is not a valid fermix-iroh pin: #{problem}")
    pin
  end

  defp entries(pin) do
    Enum.map(pin["targets"], fn {target, entry} -> {"targets.#{target}", entry} end) ++
      [{"notices", pin["notices"]}]
  end

  defp entry_problem({name, %{"asset" => asset, "sha256" => sha256}}) do
    cond do
      not text?(asset) or String.contains?(asset, "/") -> "#{name}.asset is invalid"
      not (is_binary(sha256) and Regex.match?(@sha256_pattern, sha256)) -> sha256_problem(name)
      true -> nil
    end
  end

  defp entry_problem({name, _entry}), do: "#{name} needs an asset and a sha256"

  defp sha256_problem(name), do: "#{name}.sha256 is not a lowercase sha256 digest"

  defp text?(value), do: is_binary(value) and value != ""

  defp target_entry!(pin, target) do
    case Map.fetch(pin["targets"], to_string(target)) do
      {:ok, entry} ->
        entry

      :error ->
        raise "fermix-iroh has no pinned build for target #{target}; the pin names " <>
                names(@targets)
    end
  end

  defp names(targets) do
    {init, [last]} = Enum.split(targets, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  defp place_file!(file, pin, target, fetcher) do
    %{"asset" => asset, "sha256" => expected} = file.entry

    action =
      if file_digest(file.path) == expected do
        keep_mode!(file.path, file.mode)
        :kept
      else
        url = "https://github.com/#{pin["repository"]}/releases/download/#{pin["tag"]}/#{asset}"
        bytes = fetch!(fetcher, file.name, target, url)
        install!(bytes, file, target, expected)
        :placed
      end

    %{action: action, path: file.path}
  end

  defp fetch!(fetcher, name, target, url) when is_function(fetcher, 1) do
    case fetcher.(url) do
      {:ok, bytes} when is_binary(bytes) ->
        bytes

      {:error, reason} ->
        raise "cannot fetch the fermix-iroh #{name} for #{target} from #{url}: " <>
                transport_reason(reason)
    end
  end

  defp transport_reason({:http_status, status}), do: "HTTP #{status}"
  defp transport_reason(%{__exception__: true} = exception), do: Exception.message(exception)
  defp transport_reason(reason), do: inspect(reason)

  # The temporary file sits beside the destination, so the rename is atomic and
  # a failure at any step leaves the old destination as it was and no temporary
  # file behind.
  defp install!(bytes, %{name: name, path: destination, mode: mode}, target, expected) do
    dir = Path.dirname(destination)
    File.mkdir_p!(dir)

    temporary =
      Path.join(dir, ".#{Path.basename(destination)}.#{System.unique_integer([:positive])}.tmp")

    try do
      File.write!(temporary, bytes)
      verify_digest!(name, target, expected, file_digest(temporary))
      File.chmod!(temporary, mode)
      File.rename!(temporary, destination)
      verify_digest!(name, target, expected, file_digest(destination))
    after
      remove_leftover!(temporary)
    end
  end

  # `File.chmod!/2` also stamps the file's times, so a kept file that already
  # has its mode is not touched at all.
  defp keep_mode!(path, mode) do
    if Bitwise.band(File.stat!(path).mode, 0o777) != mode, do: File.chmod!(path, mode)
    :ok
  end

  defp remove_leftover!(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise "cannot remove the temporary file #{path}: #{inspect(reason)}"
    end
  end

  defp verify_digest!(_name, _target, expected, expected), do: :ok

  defp verify_digest!(name, target, expected, actual) do
    raise "the fermix-iroh #{name} fetched for #{target} has digest #{actual || "none"}, " <>
            "and the pin names #{expected}"
  end

  defp file_digest(path) do
    case File.read(path) do
      {:ok, bytes} -> :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      {:error, :enoent} -> nil
      {:error, reason} -> raise "cannot read #{path}: #{inspect(reason)}"
    end
  end

  defp payload_priv!(work_dir) do
    case Path.wildcard(Path.join([work_dir, "lib", "fermix_core-*", "priv"])) do
      [priv] ->
        priv

      [] ->
        raise "expected exactly one fermix_core priv directory under #{work_dir}/lib, found none"

      privs ->
        raise "expected exactly one fermix_core priv directory under #{work_dir}/lib, " <>
                "found #{length(privs)}: #{Enum.join(privs, ", ")}"
    end
  end

  defp report(%{action: action, path: path, notices: notices, version: version}, target) do
    IO.puts("fermix: fermix-iroh #{version} for #{target} #{action} at #{path}")
    IO.puts("fermix: its third-party notices #{notices.action} at #{notices.path}")
  end
end
