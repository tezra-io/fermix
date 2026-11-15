defmodule FermixCore.Tools.WebFetch.EvalFixture do
  @moduledoc """
  The one origin `web_fetch` dials without the public-address check
  (`Net.Guard`), and only in a development or test build: the eval runners'
  fixture server on loopback (`benchmark/bin/evallib/fixture_server.py`),
  which the eval daemon script (`benchmark/bin/capability-daemon.sh`) names
  in `FERMIX_EVAL_FIXTURE_ORIGIN` from the port the eval home's seed
  recorded in `eval-fixtures/fixture_server.json`.

  The build decides first, at compile time (`Mix.env/0`): a build compiled
  for anything but `:dev` or `:test`, which every release is, reads neither
  the variable nor the manifest, and every URL goes through the guard. The
  compiled-in environment is the only one `decide/2` consults; no caller can
  name another.

  Within a `:dev` or `:test` build, the variable unset, every URL goes
  through the guard, as in a release. Set, it is honoured only when its form
  is exactly `http://127.0.0.1:<port>` (a port from 1 to 65535 written
  without a leading zero, no path, no trailing slash) AND the running home
  (`ConfigStore.fermix_home/0`) holds the manifest `{"port": <port>}` with
  that same port: the variable alone, exported into a development daemon on
  any other home, honours nothing. Honoured, a URL with exactly that scheme,
  host and port and no userinfo is dialled as given, whatever its path and
  query, and every other URL, a redirect's target included, goes through the
  guard unchanged, so a fixture page cannot send `web_fetch` to any other
  private address.

  A set variable that is not honoured is refused, each case in its own words
  (`describe/1`): a malformed value, a home with no manifest, a manifest that
  cannot be read, and a manifest recording another port. `decide/2` answers
  `{:error, refusal}` for every URL, and `web_fetch` fails every call.

  The URL is read with `URI.parse/1`, the parser `Net.Guard` and `Req` read
  it with, so the origin decided on is the one dialled. Nothing but
  `web_fetch` asks this module: the guard and `Net.PinnedUrl` refuse the
  origin for every other caller in every build.
  """

  alias FermixCore.Setup.ConfigStore

  @flag "FERMIX_EVAL_FIXTURE_ORIGIN"
  @prefix "http://127.0.0.1:"
  @host "127.0.0.1"
  @manifest Path.join("eval-fixtures", "fixture_server.json")
  @envs [:dev, :test]
  @compiled_env Mix.env()

  @type refusal ::
          {:invalid_eval_fixture_origin, String.t()}
          | {:eval_fixture_manifest_missing, String.t(), Path.t()}
          | {:eval_fixture_manifest_unreadable, String.t(), Path.t(), String.t()}
          | {:eval_fixture_port_mismatch, String.t(), Path.t(), :inet.port_number()}
  @type decision :: :allow | :guard | {:error, refusal()}
  @type option :: {:home, Path.t()}

  @doc """
  Whether `web_fetch` dials `url` as given (`:allow`) or through the guard
  (`:guard`) in this build, or refuses it because the variable is set but
  not honoured. `:home` names the home whose manifest is read, the running
  home by default; it is read only in a `:dev` or `:test` build with the
  variable set.
  """
  @spec decide(String.t(), [option()]) :: decision()
  def decide(url, opts \\ []) when is_binary(url) and is_list(opts),
    do: decide_in(@compiled_env, URI.parse(url), opts)

  @doc "What `web_fetch` says, and logs, of a variable it refuses."
  @spec describe(refusal()) :: String.t()
  def describe({:invalid_eval_fixture_origin, value}) when is_binary(value) do
    "eval_fixture_origin: #{@flag} is #{inspect(value)}; its one form is " <>
      "http://127.0.0.1:<port>, and web_fetch refuses every URL until it is that or unset"
  end

  def describe({:eval_fixture_manifest_missing, value, path}) when is_binary(path) do
    "eval_fixture_origin: #{@flag} is #{inspect(value)}, but this home has no #{path}; " <>
      "the origin is honoured only in the eval home whose seed recorded its port, and " <>
      "web_fetch refuses every URL until the variable is unset or Fermix runs from that home"
  end

  def describe({:eval_fixture_manifest_unreadable, value, path, reason}) when is_binary(reason) do
    "eval_fixture_origin: #{@flag} is #{inspect(value)}, but #{path} cannot be read as " <>
      "{\"port\": <1..65535>} (#{reason}); web_fetch refuses every URL until the home is " <>
      "seeded again or the variable is unset"
  end

  def describe({:eval_fixture_port_mismatch, value, path, recorded}) when is_integer(recorded) do
    "eval_fixture_origin: #{@flag} is #{inspect(value)}, but #{path} records port " <>
      "#{recorded}; web_fetch refuses every URL until the two name the same port (seed the " <>
      "home again and restart Fermix from it) or the variable is unset"
  end

  defp decide_in(env, uri, opts) when env in @envs,
    do: decide_flag(uri, System.get_env(@flag), opts)

  defp decide_in(_env, _uri, _opts), do: :guard

  defp decide_flag(_uri, nil, _opts), do: :guard

  defp decide_flag(uri, flag, opts) do
    with {:ok, port} <- origin_port(flag),
         :ok <- recorded(port, flag, manifest_path(opts)) do
      if origin?(uri, port), do: :allow, else: :guard
    end
  end

  defp origin_port(@prefix <> digits = flag) do
    with {port, ""} when port in 1..65_535 <- Integer.parse(digits),
         true <- Integer.to_string(port) == digits do
      {:ok, port}
    else
      _not_a_port -> {:error, {:invalid_eval_fixture_origin, flag}}
    end
  end

  defp origin_port(flag), do: {:error, {:invalid_eval_fixture_origin, flag}}

  defp manifest_path(opts),
    do: opts |> Keyword.get_lazy(:home, &ConfigStore.fermix_home/0) |> Path.join(@manifest)

  defp recorded(port, flag, path) do
    case read_manifest(path) do
      {:ok, ^port} -> :ok
      {:ok, other} -> {:error, {:eval_fixture_port_mismatch, flag, path, other}}
      :missing -> {:error, {:eval_fixture_manifest_missing, flag, path}}
      {:error, reason} -> {:error, {:eval_fixture_manifest_unreadable, flag, path, reason}}
    end
  end

  defp read_manifest(path) do
    case File.read(path) do
      {:ok, text} -> manifest_port(text)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason |> :file.format_error() |> to_string()}
    end
  end

  defp manifest_port(text) do
    case Jason.decode(text) do
      {:ok, %{"port" => port}} when is_integer(port) and port in 1..65_535 -> {:ok, port}
      {:ok, other} -> {:error, "it holds #{inspect(other)}"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp origin?(%URI{scheme: "http", host: @host, port: port, userinfo: nil}, port), do: true
  defp origin?(%URI{}, _port), do: false
end
