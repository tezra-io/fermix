defmodule FermixCore.Tools.PlaceSearch.AppleMaps do
  @moduledoc """
  Apple Maps place search: one `fermix-maps` helper process per search
  (M72 §14).

  The helper is a Swift executable `fermix_nif`'s Makefile builds on a native
  macOS build into `priv/fermix-maps`, beside the `disclaim` shim
  (`apps/fermix_nif/swift_src/fermix_maps.swift` holds its contract). It runs
  one `MKLocalSearch` for points of interest and prints MapKit's raw fields;
  normalizing them into the M31 record (§10.2) is this module's job.

  ## The one-shot contract

      fermix-maps        < {"query": ..., "anchor": {"kind": "query_only"}}
                         < {"query": ..., "anchor": {"kind": "location", "location": ...}}
                         < {"query": ..., "anchor": {"kind": "coordinates", "latitude": ...,
                                                     "longitude": ..., "radius_meters": ...}}

  One request line goes in on stdin, never on the command line, where every
  process on the Mac could read the place being searched. Exit 0 prints
  `{"places": [...]}`; a failure prints `{"error": {"message": ...}}` in the
  framework's own words and exits with its kind: 64 usage, 65 a named location
  that geocoded to nothing (`invalid_location`), 66 throttled
  (`rate_limited`), 67 offline (`network`), 68 any other MapKit or geocoder
  failure (`provider_error`), 69 the helper's own 12 s bound (`network`). 70,
  71, 72, 74 and 75 are the disclaim shim's, before the helper ran.

  ## The process

  Spawned through the `disclaim` exec shim on macOS, so the helper is its own
  TCC responsible process rather than an extension of the daemon's identity;
  a missing shim refuses loud and there is no undisclaimed spawn.
  `spawn_plan/3` is a deliberate copy of
  `FermixChannels.Mobile.Iroh.Helper.spawn_plan/3`, pinned by its own test.
  Every call is bounded at 15 s and the helper's process
  group is killed when the call ends, whatever ended it. The helper never
  creates a `CLLocationManager` and never reads where the Mac is.

  ## The record

  `name`; `location` from the placemark coordinate; `address`, one line;
  `contact.telephone`; `canonical_url`, the place's own site, only when HTTPS
  (an HTTP site is dropped, never rewritten); `categories`, one snake-case
  word from the point-of-interest category; `source_url`, Apple's own page for
  the place (`https://maps.apple.com/place?place-id=<id>`), which plays the
  provider-page role, so a reply links it and its card attaches; and
  `apple_place_id`, the identifier a Mac opens the place by. `distance` is
  great-circle from explicit coordinates only, in the caller's units: a
  distance from a town's centre would read as a fact about the person. Rating,
  price, hours, description, cuisines and pictures are absent: MapKit's search
  does not carry them. A result with neither an identifier nor an HTTPS site
  has no page to link and is dropped.
  """

  @behaviour FermixCore.Tools.PlaceSearch.Backend

  alias FermixCore.ProcessGroup
  alias FermixCore.Tools.PlaceSearch.Backend
  alias FermixCore.Tools.SnippetSanitizer

  @timeout_ms 15_000
  @max_stdout_bytes 1_048_576
  @max_places 10
  @default_radius_meters 5_000
  @max_message_chars 200
  @earth_radius_km 6_371.0088
  @kilometres_per_mile 1.609344
  @place_page "https://maps.apple.com/place?place-id="
  @category ~r/\AMKPOICategory([A-Z][A-Za-z]*)\z/

  @exit_reasons %{
    64 => "provider_error: the Apple Maps helper refused the request",
    65 => "invalid_location: Apple Maps found no place by that name",
    66 => "rate_limited: Apple Maps is throttling searches from this Mac",
    67 => "network: Apple Maps could not be reached",
    68 => "provider_error: Apple Maps failed",
    69 => "network: Apple Maps did not answer within 12 s"
  }
  @shim_exits [70, 71, 72, 74, 75]

  @shim_missing "provider_error: macOS disclaim shim is not built — rebuild fermix " <>
                  "(mix compile) or reinstall"
  @helper_missing "provider_error: the Apple Maps helper (fermix-maps) is missing from this " <>
                    "build — rebuild fermix (mix compile) or reinstall"

  @impl true
  @spec name() :: :apple_maps
  def name, do: :apple_maps

  @doc "Where the build puts the helper: `fermix_nif`'s `priv/fermix-maps`."
  @spec helper_path() :: Path.t()
  def helper_path, do: Application.app_dir(:fermix_nif, "priv/fermix-maps")

  @doc """
  Ready when the spawn a search would make can be made: the helper on disk
  and, on macOS, the disclaim shim beside it. `:helper_path`, `:shim_path` and
  `:os_type` name others for a test; nothing here runs the helper.
  """
  @impl true
  @spec ready(keyword()) :: :ok | {:error, String.t()}
  def ready(opts) when is_list(opts) do
    with {:ok, _plan} <- plan(opts), do: :ok
  end

  @doc """
  Runs one search. `opts` may name `:helper_path`, `:shim_path`, `:os_type`
  and `:timeout_ms` for a test; each defaults to the real one.
  """
  @impl true
  @spec search(Backend.request(), keyword()) ::
          {:ok, [Backend.place()], Backend.trace_metadata()}
          | {:error, String.t(), Backend.trace_metadata()}
  def search(%{query: query} = request, opts) when is_binary(query) and is_list(opts) do
    with {:ok, {executable, args}} <- plan(opts),
         {:ok, stdout} <- run(executable, args, request_line(request), timeout(opts)),
         {:ok, raw} <- decode(stdout),
         {:ok, places} <- places(raw, request) do
      {:ok, places, %{}}
    else
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  @doc """
  The spawn target and argv: on macOS through the `disclaim` exec shim, so the
  helper is its own TCC responsible process. A missing shim refuses; there is
  no undisclaimed spawn. A deliberate copy of
  `FermixChannels.Mobile.Iroh.Helper.spawn_plan/3`, pinned by its own test.
  """
  @spec spawn_plan(Path.t(), {atom(), atom()}, Path.t() | nil) ::
          {:ok, {Path.t(), [String.t()]}} | {:error, String.t()}
  def spawn_plan(_helper, {:unix, :darwin}, nil), do: {:error, @shim_missing}

  def spawn_plan(helper, {:unix, :darwin}, shim) when is_binary(shim),
    do: {:ok, {shim, [helper]}}

  def spawn_plan(helper, _os_type, _shim), do: {:ok, {helper, []}}

  @doc """
  The helper's raw places normalized into M31 records (pure): at most
  #{@max_places}, in MapKit's order, each kept only with a name and a page to
  link. A field of an unexpected type is `parser_changed`, never a guess.
  """
  @spec places([term()], Backend.request()) :: {:ok, [Backend.place()]} | {:error, String.t()}
  def places(raw, request) when is_list(raw) and is_map(request) do
    raw
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, kept} ->
      case place(entry, request) do
        {:ok, nil} -> {:cont, {:ok, kept}}
        {:ok, place} -> {:cont, {:ok, [place | kept]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> take_places()
  end

  # -- the request -----------------------------------------------------------

  defp request_line(request) do
    Jason.encode!(%{"query" => request.query, "anchor" => anchor(request)})
  end

  defp anchor(%{anchor: {:location, location}}),
    do: %{"kind" => "location", "location" => location}

  defp anchor(%{anchor: {:coordinates, latitude, longitude}} = request) do
    %{
      "kind" => "coordinates",
      "latitude" => latitude,
      "longitude" => longitude,
      "radius_meters" => Map.get(request, :radius_meters, @default_radius_meters)
    }
  end

  defp anchor(_request), do: %{"kind" => "query_only"}

  # -- the process -----------------------------------------------------------

  # The one spawn `ready/1` and `search/2` both build, so a call is never
  # advertised and then refused for a part that was never there.
  defp plan(opts) do
    with {:ok, helper} <- helper(opts), do: spawn_plan(helper, os_type(opts), shim_path(opts))
  end

  defp helper(opts) do
    path = Keyword.get_lazy(opts, :helper_path, &helper_path/0)
    if File.regular?(path), do: {:ok, path}, else: {:error, @helper_missing}
  end

  defp shim_path(opts), do: Keyword.get_lazy(opts, :shim_path, &disclaim_shim_path/0)

  defp disclaim_shim_path do
    path = Application.app_dir(:fermix_nif, "priv/disclaim")
    if File.regular?(path), do: path, else: nil
  end

  defp os_type(opts), do: Keyword.get_lazy(opts, :os_type, &:os.type/0)
  defp timeout(opts), do: Keyword.get(opts, :timeout_ms, @timeout_ms)

  # The port is unlinked and monitored before the request is written: a helper
  # that died before reading closes the port on the write (EPIPE), which then
  # arrives here as a `:DOWN` this call answers, not as an exit signal that
  # ends the turn running it.
  defp run(executable, args, line, timeout_ms) do
    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, :hide, args: args])
    os_pid = os_pid(port)
    Process.unlink(port)
    monitor = Port.monitor(port)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      :ok = command(port, line)
      collect(port, monitor, deadline, timeout_ms, "")
    after
      teardown(port, monitor, os_pid)
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, "provider_error: the Apple Maps helper could not be started: #{inspect(error)}"}
  end

  # A helper that exited at once (seen under load) has closed its port before
  # its pid is read or its request written: Port.info/2 answers nil and the
  # write raises. It did start, and what it printed and its exit status are
  # still in the mailbox, which `collect/5` reads as usual.
  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp command(port, line) do
    Port.command(port, [line, ?\n])
    :ok
  rescue
    ArgumentError -> :ok
  end

  # One receive loop, bounded by the call's deadline and by the stdout ceiling.
  defp collect(port, monitor, deadline, timeout_ms, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} -> more(port, monitor, deadline, timeout_ms, acc <> chunk)
      {^port, {:exit_status, status}} -> finish(status, acc)
      {:DOWN, ^monitor, :port, ^port, reason} -> {:error, closed(reason)}
    after
      remaining ->
        {:error, "network: the Apple Maps helper did not answer within #{timeout_ms} ms"}
    end
  end

  defp more(_port, _monitor, _deadline, _timeout_ms, acc) when byte_size(acc) > @max_stdout_bytes,
    do:
      {:error,
       "response_too_large: the Apple Maps helper printed over #{@max_stdout_bytes} bytes"}

  defp more(port, monitor, deadline, timeout_ms, acc),
    do: collect(port, monitor, deadline, timeout_ms, acc)

  defp closed(reason),
    do: "provider_error: the Apple Maps helper closed before answering (#{inspect(reason)})"

  # The call is over whatever ended it: the port is closed and the helper's
  # process group killed. `:esrch` (already gone) is silent success. A helper
  # whose pid was never read had already exited, and names no group.
  defp teardown(port, monitor, os_pid) do
    Port.demonitor(monitor, [:flush])
    if Port.info(port), do: Port.close(port)
    if os_pid, do: ProcessGroup.signal(os_pid, :sigkill)
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp finish(0, stdout), do: {:ok, stdout}
  defp finish(status, stdout), do: {:error, exit_reason(status, stdout)}

  defp exit_reason(status, stdout) when is_map_key(@exit_reasons, status),
    do: Map.fetch!(@exit_reasons, status) <> helper_words(stdout)

  defp exit_reason(status, _stdout) when status in @shim_exits,
    do: "provider_error: the disclaim shim could not start the Apple Maps helper (exit #{status})"

  defp exit_reason(status, _stdout),
    do: "provider_error: the Apple Maps helper exited with status #{status}"

  # The framework's own words, as the helper printed them: sanitized and cut,
  # and absent when stdout is not the error object.
  defp helper_words(stdout) do
    case Jason.decode(String.trim(stdout)) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) ->
        case message |> SnippetSanitizer.sanitize() |> String.slice(0, @max_message_chars) do
          "" -> ""
          words -> " (#{words})"
        end

      _other ->
        ""
    end
  end

  defp decode(stdout) do
    case Jason.decode(String.trim(stdout)) do
      {:ok, %{"places" => places}} when is_list(places) -> {:ok, places}
      {:ok, _other} -> {:error, parser_changed("places", "an array")}
      {:error, %Jason.DecodeError{position: at}} -> {:error, "parser_changed: not JSON at #{at}"}
    end
  end

  # -- the record (pure) -----------------------------------------------------

  defp take_places({:ok, kept}), do: {:ok, kept |> Enum.reverse() |> Enum.take(@max_places)}
  defp take_places({:error, reason}), do: {:error, reason}

  defp place(entry, request) when is_map(entry) do
    with {:ok, name} <- text(entry, "name"),
         {:ok, identifier} <- identifier(entry),
         {:ok, site} <- https_url(entry),
         {:ok, location} <- location(entry),
         {:ok, address} <- address(entry),
         {:ok, telephone} <- text(entry, "phone"),
         {:ok, category} <- category(entry) do
      fields = %{location: location, address: address, telephone: telephone, category: category}
      {:ok, retain(name, identifier, site, fields, request)}
    end
  end

  defp place(_entry, _request), do: {:error, parser_changed("places[]", "an object")}

  # No name, or no page a reader can open, and the place is dropped.
  defp retain(nil, _identifier, _site, _fields, _request), do: nil
  defp retain(_name, nil, nil, _fields, _request), do: nil

  defp retain(name, identifier, site, fields, request) do
    %{name: name}
    |> put_present(:canonical_url, site)
    |> put_present(:source_url, identifier && @place_page <> URI.encode_www_form(identifier))
    |> put_present(:apple_place_id, identifier)
    |> put_present(:location, fields.location)
    |> put_present(:address, fields.address)
    |> put_present(:contact, fields.telephone && %{telephone: fields.telephone})
    |> put_present(:categories, fields.category && [fields.category])
    |> put_present(:distance, distance(request, fields.location))
  end

  defp text(entry, key) do
    case Map.get(entry, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, blank_to_nil(SnippetSanitizer.sanitize(value))}
      _other -> {:error, parser_changed(key, "a string")}
    end
  end

  # An identifier is Apple's, kept exactly as it came.
  defp identifier(entry) do
    case Map.get(entry, "identifier") do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, blank_to_nil(String.trim(value))}
      _other -> {:error, parser_changed("identifier", "a string")}
    end
  end

  # The place's own site, exactly as returned and only when HTTPS: an HTTP
  # site is absent, never rewritten into HTTPS.
  defp https_url(entry) do
    case Map.get(entry, "url") do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, valid_https(String.trim(value))}
      _other -> {:error, parser_changed("url", "a string")}
    end
  end

  defp valid_https(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> url
      _other -> nil
    end
  end

  defp location(entry) do
    case {Map.get(entry, "latitude"), Map.get(entry, "longitude")} do
      {nil, nil} ->
        {:ok, nil}

      {latitude, longitude}
      when is_number(latitude) and latitude >= -90 and latitude <= 90 and
             is_number(longitude) and longitude >= -180 and longitude <= 180 ->
        {:ok, %{latitude: latitude, longitude: longitude}}

      _other ->
        {:error, parser_changed("latitude/longitude", "a pair of coordinates in range")}
    end
  end

  # MapKit writes a multi-line address in some regions; the record carries one.
  defp address(entry) do
    case Map.get(entry, "address") do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, one_line(value)}
      _other -> {:error, parser_changed("address", "a string")}
    end
  end

  defp one_line(address) do
    address
    |> String.split(~r/\R/u)
    |> Enum.map(&SnippetSanitizer.sanitize/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
    |> blank_to_nil()
  end

  # `MKPOICategoryEVCharger` is `ev_charger`: one snake-case word.
  defp category(entry) do
    case Map.get(entry, "category") do
      nil -> {:ok, nil}
      value when is_binary(value) -> category_word(value)
      _other -> {:error, parser_changed("category", "a string")}
    end
  end

  defp category_word(value) do
    case Regex.run(@category, value, capture: :all_but_first) do
      [camel] -> {:ok, snake_case(camel)}
      nil -> {:error, parser_changed("category", "an MKPOICategory name")}
    end
  end

  defp snake_case(camel) do
    camel
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.downcase()
  end

  # Great-circle, from the caller's own coordinates only.
  defp distance(%{anchor: {:coordinates, latitude, longitude}} = request, %{} = location) do
    kilometres = kilometres({latitude, longitude}, {location.latitude, location.longitude})

    case Map.get(request, :units) do
      :imperial -> %{value: Float.round(kilometres / @kilometres_per_mile, 2), units: "mi"}
      _metric -> %{value: Float.round(kilometres, 2), units: "km"}
    end
  end

  defp distance(_request, _location), do: nil

  defp kilometres({lat1, lng1}, {lat2, lng2}) do
    phi1 = radians(lat1)
    phi2 = radians(lat2)
    half_dphi = radians(lat2 - lat1) / 2
    half_dlambda = radians(lng2 - lng1) / 2

    a =
      :math.sin(half_dphi) * :math.sin(half_dphi) +
        :math.cos(phi1) * :math.cos(phi2) * :math.sin(half_dlambda) * :math.sin(half_dlambda)

    2 * @earth_radius_km * :math.asin(min(1.0, :math.sqrt(a)))
  end

  defp radians(degrees), do: degrees * :math.pi() / 180

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp parser_changed(field, expected), do: "parser_changed: #{field} must be #{expected}"
end
