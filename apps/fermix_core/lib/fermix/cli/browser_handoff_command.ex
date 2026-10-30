defmodule Fermix.CLI.BrowserHandoffCommand do
  @moduledoc """
  `fermix browser signin|handoff|handoffs` (M75 D18, §14): the owner's
  browser hand-off, over the running engine's `daemon.sock`.

      fermix browser signin URL [--json]
      fermix browser handoff SITE... [--expires DURATION] [--allow-identity-provider] [--json]
      fermix browser handoffs [--json]
      fermix browser handoffs wipe [SITE...] [--json]

  `signin` opens the address in Chrome on the Fermix profile for the owner to
  sign in (`browser.signin.open`). `handoff`, on a desktop whose home moved
  to a server, sends that profile's cookies for exactly the named sites (a
  host and its subdomains) to the server (`browser.handoff.send`); an
  identity provider moves only with `--allow-identity-provider`.
  `--expires` takes a whole number of days, hours or minutes (`7d`, `12h`,
  `90m`): 7 days when absent, at most 30. `handoffs` lists what the server
  stores (`browser.handoffs.list`, forwarded from a desktop), and `handoffs
  wipe` deletes the named sites' hand-offs, or every one
  (`browser.handoffs.wipe`): on the server, now; on a desktop, by asking the
  server.

  Each needs Fermix running (`engine_stopped` otherwise). `--json` prints the
  management result unchanged (`priv/cli/CONTRACT.md`); without it a few lines
  on stdout and a refusal one sentence on stderr. Exit status: `0` done, `1`
  refused, `2` usage error.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.MachineOutput
  alias FermixCore.Setup.ConfigStore

  @json [json: :boolean]
  @handoff_switches [expires: :string, allow_identity_provider: :boolean, json: :boolean]
  # A hand-off waits for the server to store the cookies, which may start its
  # browser, behind the desktop's own read of its profile.
  @call_timeout_ms 120_000
  @duration ~r/\A([1-9][0-9]{0,6})([dhm])\z/
  @unit_seconds %{"d" => 86_400, "h" => 3_600, "m" => 60}
  @usage """
  Usage:
    fermix browser signin URL [--json]
    fermix browser handoff SITE... [--expires DURATION] [--allow-identity-provider] [--json]
    fermix browser handoffs [--json]
    fermix browser handoffs wipe [SITE...] [--json]
  """

  @doc """
  Runs `fermix browser signin ARGS`. `deps`: `:home`, `:client` (a 3-arity
  management call, as `Client.request_v1/3`).
  """
  @spec signin([String.t()], keyword()) :: non_neg_integer()
  def signin(argv, deps \\ []) when is_list(argv) and is_list(deps) do
    case OptionParser.parse(argv, strict: @json) do
      {opts, [url], []} ->
        call(json?(opts), deps, "browser.signin.open", %{"url" => url}, &signin_lines/1)

      _invalid ->
        usage()
    end
  end

  @doc "Runs `fermix browser handoff ARGS`, with the dependencies `signin/2` takes."
  @spec handoff([String.t()], keyword()) :: non_neg_integer()
  def handoff(argv, deps \\ []) when is_list(argv) and is_list(deps) do
    with {opts, [_ | _] = sites, []} <- OptionParser.parse(argv, strict: @handoff_switches),
         {:ok, params} <- handoff_params(opts, sites) do
      call(json?(opts), deps, "browser.handoff.send", params, &handoff_lines/1)
    else
      _invalid -> usage()
    end
  end

  @doc "Runs `fermix browser handoffs ARGS`, with the dependencies `signin/2` takes."
  @spec handoffs([String.t()], keyword()) :: non_neg_integer()
  def handoffs(argv, deps \\ []) when is_list(argv) and is_list(deps) do
    case OptionParser.parse(argv, strict: @json) do
      {opts, [], []} ->
        call(json?(opts), deps, "browser.handoffs.list", %{}, &list_lines/1)

      {opts, ["wipe"], []} ->
        call(json?(opts), deps, "browser.handoffs.wipe", %{}, &sentence_lines/1)

      {opts, ["wipe" | sites], []} ->
        call(json?(opts), deps, "browser.handoffs.wipe", %{"sites" => sites}, &sentence_lines/1)

      _invalid ->
        usage()
    end
  end

  defp handoff_params(opts, sites) do
    params = %{
      "sites" => sites,
      "allow_identity_provider" => Keyword.get(opts, :allow_identity_provider, false)
    }

    case Keyword.fetch(opts, :expires) do
      :error ->
        {:ok, params}

      {:ok, text} ->
        with {:ok, seconds} <- duration(text), do: {:ok, Map.put(params, "expires_s", seconds)}
    end
  end

  @doc "Seconds in a duration such as `7d`, `12h` or `90m`; `:error` for anything else."
  @spec duration(String.t()) :: {:ok, pos_integer()} | :error
  def duration(text) when is_binary(text) do
    case Regex.run(@duration, text) do
      [_whole, count, unit] -> {:ok, String.to_integer(count) * Map.fetch!(@unit_seconds, unit)}
      nil -> :error
    end
  end

  defp call(json?, deps, method, params, lines) do
    home = Path.expand(Keyword.get_lazy(deps, :home, &ConfigStore.fermix_home/0))
    client = Keyword.get(deps, :client, &Client.request_v1/3)
    opts = [socket_path: Path.join(home, "daemon.sock"), timeout: @call_timeout_ms]

    case client.(method, params, opts) do
      {:ok, result} -> report(json?, result, lines)
      {:error, :not_running} -> refuse(json?, :engine_stopped, [])
      {:error, {:management_error, _code, message, details}} -> refused(json?, message, details)
      {:error, reason} -> refuse(json?, :browser_refused, output: Client.describe_error(reason))
    end
  end

  # The engine's own sentence, when it gave one, is what the owner reads.
  defp refused(json?, message, details) do
    said =
      case details do
        %{"sentence" => sentence} when is_binary(sentence) -> sentence
        _none -> message
      end

    refuse(json?, :browser_refused, output: said)
  end

  defp report(true, result, _lines) do
    IO.puts(MachineOutput.ok(result))
    0
  end

  defp report(false, result, lines) do
    Enum.each(lines.(result), &IO.puts/1)
    0
  end

  defp refuse(true, code, details) do
    IO.puts(MachineOutput.error(code, details))
    1
  end

  defp refuse(false, code, details) do
    IO.puts(:stderr, "fermix browser: " <> MachineOutput.sentence(code, details))
    1
  end

  defp sentence_lines(%{"sentence" => sentence}), do: [sentence]

  # The engine's sentence says what to do next in words every surface can
  # show; the verb that does it from here is this command's own line.
  defp signin_lines(%{"sentence" => sentence}),
    do: [sentence, "Then run: fermix browser handoff SITE..."]

  defp handoff_lines(result) do
    sites =
      Enum.map(result["sites"], fn %{"site" => site, "cookies" => n} ->
        "  #{site}: #{n} cookies"
      end)

    ["Sent #{result["cookies_sent"]} cookies:"] ++ sites ++ [result["sentence"]]
  end

  defp list_lines(%{"handoffs" => rows, "sentence" => sentence}),
    do: [sentence | Enum.map(rows, &row_line/1)]

  defp row_line(row) do
    state = if row["expired"], do: "expired", else: "until #{row["expires_at"]}"

    "  #{Enum.join(row["sites"], ", ")}: #{row["cookies"]} cookies from #{row["from"]}, #{state}"
  end

  defp json?(opts), do: Keyword.get(opts, :json, false)

  defp usage do
    IO.puts(:stderr, @usage)
    2
  end
end
