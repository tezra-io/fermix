defmodule FermixCore.Net.EgressSurfaceTest do
  @moduledoc """
  The whole outbound surface, not connector by connector.

  `FermixCore.Net.Egress` only means something if nothing dials around it, and
  a new call site is one `Req.get/2` away from doing exactly that: it would work
  on every machine with a direct route and quietly ignore the proxy on the ones
  that have none. So this reads the source of every umbrella app that dials.

    * Every `Req` request is routed through `Egress.attach/3`.
    * Every other way of opening a connection (a WebSocket client, raw Mint,
      `:httpc`, Finch used directly, a TCP or TLS socket, a library that dials
      for us) either asks `Egress.ensure_direct/2` first or is listed below with
      the reason no route decision exists for it.

  What it cannot see: a call through a module held in a variable, and a
  dependency that dials on its own. The dependencies that do are named here one
  by one (`@delegated_dialers`), which is why adding one means reading how it
  connects.
  """

  use ExUnit.Case, async: true

  @umbrella Path.expand("../../../../..", __DIR__)
  @scanned ~w(fermix_core fermix_channels fermix_web fermix_opik)

  @req_verbs "request|get|post|put|patch|delete|head|run"
  @req_execution Regex.compile!(
                   "\\bReq\\.(?:#{@req_verbs})!?\\(|\\bReq\\.Request\\.run_request\\(|" <>
                     "&Req\\.(?:#{@req_verbs})!?/\\d"
                 )

  # Counted in pipeline position only, so a mention in a doc string or a comment
  # cannot stand in for a routed call.
  @routed ~r/\|>\s*(?:Egress\.attach\(|route_through_fermix_egress\(\))/

  # Opening a connection without `Req`. A Unix-domain socket (`{:local, path}`)
  # is not a network destination and is left out by the pattern itself.
  @dial Regex.compile!(
          Enum.join(
            [
              "\\bWebSockex\\.start(?:_link)?\\(",
              "\\bMint\\.HTTP[12]?\\.connect\\(",
              ":httpc\\.request\\(",
              "\\bFinch\\.(?:request|stream|stream_while|async_request)\\(",
              ":ssl\\.connect\\(",
              ":gen_tcp\\.connect\\((?!\\s*\\{:local\\b)",
              "\\bPigeon\\.Dispatcher\\.start_link\\("
            ],
            "|"
          )
        )

  @asks_first ~r/\bEgress\.ensure_direct\(/

  # A dial with no route to decide, and why.
  @direct_by_construction %{
    # The probe socket itself. Its target is chosen by the caller, and
    # `Jobs.Runner` asks `Egress.readiness_target/3` for it.
    "apps/fermix_core/lib/fermix_core/net/readiness.ex" => :target_chosen_by_egress,
    # `fermix service` asking this machine's own web listener whether it is up.
    "apps/fermix_core/lib/fermix/cli/service.ex" => :own_listener_health,
    # `fermix setup` waiting for its own setup listener on 127.0.0.1.
    "apps/fermix_core/lib/fermix/cli/setup/web_launcher.ex" => :own_listener_health
  }

  # Dependencies that open connections themselves. Each is handed a routed
  # fetcher or guarded by `ensure_direct/2` at the one place Fermix calls it.
  @delegated_dialers %{
    # compux downloads with `:httpc` unless it is given a fetcher (looked for on
    # the line of the call).
    ~r/\bCompux\.Binary\.path\((?![^\n]*\bfetcher:)/ => "Compux.Binary.path/1 without a fetcher"
  }

  # The sites this gate exists for. If a refactor moves one, the scan must still
  # find it: a gate that walked the wrong files would pass forever.
  @known_req_sites [
    "apps/fermix_core/lib/fermix_core/net/http_client.ex",
    "apps/fermix_core/lib/fermix_core/tools/web_fetch.ex",
    "apps/fermix_core/lib/fermix_core/auth/refresh_client.ex",
    "apps/fermix_core/lib/fermix_core/setup/doctor.ex",
    "apps/fermix_core/lib/fermix_core/computer_use/sidecar_installer.ex",
    "apps/fermix_channels/lib/fermix_channels/channels/telegram/poller.ex",
    "apps/fermix_opik/lib/fermix_opik/client.ex"
  ]

  @known_dial_sites [
    "apps/fermix_core/lib/fermix_core/realtime/openai_client.ex",
    "apps/fermix_core/lib/fermix_core/capabilities/mcp/remote/connection.ex",
    "apps/fermix_channels/lib/fermix_channels/channels/discord/gateway/socket.ex",
    "apps/fermix_channels/lib/fermix_channels/mobile/push_pigeon_dispatcher.ex"
  ]

  test "every Req request is routed through the egress policy" do
    sites = sites(@req_execution)

    for known <- @known_req_sites do
      assert Map.has_key?(sites, known), "the scan no longer finds #{known}"
    end

    unrouted =
      for {path, executions} <- sites, executions > count(path, @routed) do
        "#{path}: #{executions} Req call(s), #{count(path, @routed)} routed"
      end

    assert unrouted == [],
           "these files send an HTTP request that Net.Egress never sees, so it would " <>
             "ignore a configured proxy:\n  " <> Enum.join(Enum.sort(unrouted), "\n  ")
  end

  # The exporter app does not depend on fermix_core, so it reaches the policy by
  # name. That indirection is only a route if it really lands on `attach/3`.
  test "the trace exporter's by-name route calls Egress.attach/3" do
    source = read("apps/fermix_opik/lib/fermix_opik/client.ex")

    assert source =~ "apply(FermixCore.Net.Egress, :attach, [request, :direct])"
  end

  test "every other dial asks the egress policy first, or says why it need not" do
    sites = sites(@dial)

    for known <- @known_dial_sites do
      assert Map.has_key?(sites, known), "the scan no longer finds #{known}"
    end

    unasked =
      for {path, dials} <- sites,
          not Map.has_key?(@direct_by_construction, path),
          dials > count(path, @asks_first) do
        "#{path}: #{dials} dial(s), #{count(path, @asks_first)} ask Egress.ensure_direct/2"
      end

    assert unasked == [],
           "these files open a connection without Egress.ensure_direct/2, so on a host " <>
             "with a proxy they would dial around it:\n  " <>
             Enum.join(Enum.sort(unasked), "\n  ")
  end

  test "every stated exception still exists and still dials" do
    sites = sites(@dial)

    for {path, _reason} <- @direct_by_construction do
      assert Map.has_key?(sites, path), "#{path} is exempted but no longer dials"
    end
  end

  test "a dependency that dials on its own is never called unrouted" do
    for {pattern, what} <- @delegated_dialers do
      offenders = sites(pattern) |> Map.keys() |> Enum.sort()

      assert offenders == [], "#{what} dials outside Net.Egress in: #{Enum.join(offenders, ", ")}"
    end
  end

  # path (relative to the umbrella) => number of matches, for files with any.
  defp sites(pattern) do
    for path <- source_files(), matches = count(path, pattern), matches > 0, into: %{} do
      {path, matches}
    end
  end

  defp source_files do
    files =
      Enum.flat_map(@scanned, fn app ->
        @umbrella
        |> Path.join("apps/#{app}/lib/**/*.ex")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, @umbrella))
      end)

    assert length(files) > 500, "the scan found #{length(files)} source files; it is misdirected"
    files
  end

  defp count(path, pattern), do: length(Regex.scan(pattern, code(path)))

  # Comment lines carry prose about these calls; only code can make one.
  defp code(path) do
    path
    |> read()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
    |> Enum.join("\n")
  end

  defp read(path), do: File.read!(Path.join(@umbrella, path))
end
