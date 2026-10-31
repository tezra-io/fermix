defmodule FermixTestSupport.HetznerStub do
  @moduledoc """
  The Hetzner Cloud API as the provisioner's tests meet it (M75 lean v1
  §4.3): a plug for `Req`'s `:plug` option, so no socket opens and nothing
  leaves the machine.

  The answers are the recorded shapes in
  `apps/fermix_core/test/fixtures/hetzner/`, which follow the examples of
  Hetzner's published OpenAPI document (`docs.hetzner.cloud/cloud.spec.json`)
  field for field, with invented values: `server_types.json`, `pricing.json`,
  `locations.json` and `images_debian13.json` as `GET` answers, the
  `server`, `firewall`, `primary_ip` and `action` templates the stub fills
  with the ids, names and labels of what it creates, and `errors.json`, the
  error bodies by code.

  The stub keeps a world (an `Agent` the test owns): the one token it
  accepts, whether that token may only read, the firewalls, servers, primary
  addresses and actions it holds, and every request it was sent. An action
  answers `running` for `:action_polls` reads and then `success` (or the
  error `fail_action/3` gave it). `fault/5` queues an answer that takes the
  place of the next matching request. Every answer carries Hetzner's
  rate-limit headers. A server's create answer carries a root password, as
  Hetzner's does when no SSH key is given, so a test can prove it goes
  nowhere.
  """

  @behaviour Plug

  import Plug.Conn

  @fixtures Path.expand("../../apps/fermix_core/test/fixtures/hetzner", __DIR__)
  @root_password "invented-root-password-Q7vX"
  @token "invented-hetzner-token-6d1f0c9a2b7e4f3a"

  @doc "The token the stub accepts unless a test sets another."
  def token, do: @token

  @doc "The root password every server's create answer carries."
  def root_password, do: @root_password

  @doc "A recorded fixture, decoded."
  def fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()

  @doc "Starts a stub owned by the calling test and answers it."
  def start!(overrides \\ []) do
    world =
      Map.merge(
        %{
          token: @token,
          read_only: false,
          action_polls: 1,
          auto_delete_ips: true,
          firewalls: %{},
          servers: %{},
          primary_ips: %{},
          actions: %{},
          faults: [],
          requests: [],
          next_id: 1_000
        },
        Map.new(overrides)
      )

    ExUnit.Callbacks.start_supervised!(
      {Agent, fn -> world end},
      id: {__MODULE__, System.unique_integer([:positive])}
    )
  end

  @doc "`Req` options that send every request to `stub`."
  def req_options(stub), do: [plug: {__MODULE__, stub}]

  @doc "Every request the stub was sent, oldest first: `{method, path, query, body}`."
  def requests(stub), do: stub |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "The world as it stands."
  def world(stub), do: Agent.get(stub, & &1)

  @doc "Sets one fact of the world."
  def set(stub, key, value), do: Agent.update(stub, &Map.put(&1, key, value))

  @doc """
  Queues `times` answers of `status` with the error body `code` (from
  `errors.json`) in place of the next requests whose method is `method` and
  whose path matches `path`.
  """
  def fault(stub, method, path, status, code, times \\ 1) do
    body = Map.fetch!(fixture("errors.json"), code)
    faults = for _n <- 1..times, do: {method, path, status, body}
    Agent.update(stub, &%{&1 | faults: &1.faults ++ faults})
  end

  @doc """
  Like `fault/6`, but the request takes effect first and only its answer is
  replaced: a create Hetzner carried out whose answer was lost.
  """
  def lose_answer(stub, method, path, status, code) do
    body = Map.fetch!(fixture("errors.json"), code)
    Agent.update(stub, &%{&1 | faults: &1.faults ++ [{method, path, status, {:after, body}}]})
  end

  @doc "The next request matching `method` and `path` is answered `status` with `body` as it is."
  def answer_with(stub, method, path, status, body),
    do: Agent.update(stub, &%{&1 | faults: &1.faults ++ [{method, path, status, body}]})

  @doc "The next request matching `method` and `path` never reaches Hetzner: `reason`."
  def transport_error(stub, method, path, reason),
    do: Agent.update(stub, &%{&1 | faults: &1.faults ++ [{method, path, :transport, reason}]})

  @doc "Makes action `id` end in `error` with Hetzner's own `message`."
  def fail_action(stub, id, message) do
    Agent.update(stub, fn world ->
      update_in(world.actions[id], &Map.put(&1, :error, message))
    end)
  end

  @doc "Sets a held server's `status`, as Hetzner reports it (`off`, `running`)."
  def server_status(stub, id, status),
    do:
      Agent.update(
        stub,
        &update_in(&1.servers[id], fn server -> %{server | "status" => status} end)
      )

  @doc "Removes a server, firewall or primary address as Hetzner's console would."
  def delete_outside(stub, kind, id) when kind in [:servers, :firewalls, :primary_ips],
    do: Agent.update(stub, &update_in(&1, [kind], fn held -> Map.delete(held, id) end))

  # -- the plug ---------------------------------------------------------------

  @impl Plug
  def init(stub), do: stub

  @impl Plug
  def call(conn, stub) do
    {:ok, raw, conn} = read_body(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)
    query = URI.decode_query(conn.query_string)

    Agent.update(
      stub,
      &%{&1 | requests: [{conn.method, conn.request_path, query, body} | &1.requests]}
    )

    case answer(conn, stub, query, body) do
      {:transport, reason} -> Req.Test.transport_error(conn, reason)
      {status, answer} -> respond(conn, status, answer)
    end
  end

  defp answer(conn, stub, query, body) do
    with :ok <- authorized(conn, stub),
         :ok <- writable(conn, stub) do
      case take_fault(stub, conn.method, conn.request_path) do
        :none -> routed(conn, stub, query, body)
        {status, {:after, error}} -> after_routed(conn, stub, query, body, {status, error})
        {status, error} -> {status, error}
      end
    end
  end

  defp routed(conn, stub, query, body) do
    Agent.get_and_update(stub, fn world ->
      route(conn.method, path_parts(conn.request_path), query, body, world)
    end)
  end

  defp after_routed(conn, stub, query, body, lost) do
    _answer = routed(conn, stub, query, body)
    lost
  end

  defp authorized(conn, stub) do
    if get_req_header(conn, "authorization") == ["Bearer " <> Agent.get(stub, & &1.token)],
      do: :ok,
      else: error(401, "unauthorized")
  end

  defp writable(%{method: "GET"}, _stub), do: :ok

  defp writable(_conn, stub) do
    if Agent.get(stub, & &1.read_only), do: error(403, "forbidden"), else: :ok
  end

  defp take_fault(stub, method, path) do
    Agent.get_and_update(stub, fn world ->
      case Enum.split_with(world.faults, &fault_matches?(&1, method, path)) do
        {[{_m, _p, status, body} | rest], others} ->
          {{status, body}, %{world | faults: rest ++ others}}

        {[], _others} ->
          {:none, world}
      end
    end)
  end

  defp fault_matches?({method, pattern, _status, _body}, method, path),
    do: Regex.match?(pattern, path)

  defp fault_matches?(_fault, _method, _path), do: false

  defp respond(conn, status, answer) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("ratelimit-limit", "3600")
    |> put_resp_header("ratelimit-remaining", "3542")
    |> put_resp_header("ratelimit-reset", "1999999999")
    |> send_resp(status, if(answer == nil, do: "", else: Jason.encode!(answer)))
  end

  defp path_parts("/v1/" <> rest), do: String.split(rest, "/")

  defp error(status, code), do: {status, Map.fetch!(fixture("errors.json"), code)}

  # -- routes, each answering `{{status, body}, world}` ------------------------

  defp route("GET", ["server_types"], _query, _body, world),
    do: {{200, Map.get(world, :server_types) || fixture("server_types.json")}, world}

  defp route("GET", ["pricing"], _query, _body, world),
    do: {{200, fixture("pricing.json")}, world}

  defp route("GET", ["locations"], _query, _body, world),
    do: {{200, fixture("locations.json")}, world}

  defp route("GET", ["images"], query, _body, world) do
    images =
      if query["name"] == "debian-13", do: fixture("images_debian13.json")["images"], else: []

    {{200, %{"images" => images, "meta" => meta(images)}}, world}
  end

  defp route("POST", ["firewalls"], _query, body, world) do
    {id, world} = next_id(world)

    firewall =
      Map.merge(fixture("firewall.json"), %{
        "id" => id,
        "name" => body["name"],
        "labels" => body["labels"]
      })

    {{201, %{"firewall" => firewall, "actions" => []}}, put_in(world.firewalls[id], firewall)}
  end

  defp route("GET", ["firewalls"], query, _body, world),
    do: {{200, listing("firewalls", world.firewalls, query)}, world}

  defp route("GET", ["firewalls", id], _query, _body, world),
    do: one("firewall", world.firewalls, id, world)

  defp route("DELETE", ["firewalls", id], _query, _body, world) do
    id = String.to_integer(id)

    cond do
      not Map.has_key?(world.firewalls, id) -> {error(404, "not_found"), world}
      applied?(world, id) -> {error(422, "resource_in_use"), world}
      true -> {{204, nil}, %{world | firewalls: Map.delete(world.firewalls, id)}}
    end
  end

  defp route("POST", ["servers"], _query, body, world), do: create_server(body, world)

  defp route("GET", ["servers"], query, _body, world),
    do: {{200, listing("servers", world.servers, query)}, world}

  defp route("GET", ["servers", id], _query, _body, world),
    do: one("server", world.servers, id, world)

  defp route("DELETE", ["servers", id], _query, _body, world) do
    id = String.to_integer(id)

    case Map.fetch(world.servers, id) do
      {:ok, server} -> delete_server(server, world)
      :error -> {error(404, "not_found"), world}
    end
  end

  defp route("POST", ["servers", id, "actions", command], _query, _body, world)
       when command in ["poweron", "reset"] do
    id = String.to_integer(id)

    if Map.has_key?(world.servers, id) do
      {action, world} =
        action(
          world,
          Map.fetch!(%{"poweron" => "start_server", "reset" => "reset_server"}, command),
          id
        )

      world = update_in(world.servers[id], &Map.put(&1, "status", "running"))
      {{201, %{"action" => action}}, world}
    else
      {error(404, "not_found"), world}
    end
  end

  defp route("GET", ["actions", id], _query, _body, world), do: poll(String.to_integer(id), world)

  defp route("GET", ["primary_ips", id], _query, _body, world),
    do: one("primary_ip", world.primary_ips, id, world)

  defp route("DELETE", ["primary_ips", id], _query, _body, world) do
    id = String.to_integer(id)

    if Map.has_key?(world.primary_ips, id),
      do: {{204, nil}, %{world | primary_ips: Map.delete(world.primary_ips, id)}},
      else: {error(404, "not_found"), world}
  end

  defp route(_method, _parts, _query, _body, world), do: {error(404, "not_found"), world}

  # -- servers ----------------------------------------------------------------

  defp create_server(body, world) do
    {id, world} = next_id(world)
    {ipv4, world} = primary_ip(world, "ipv4", "203.0.113.#{rem(id, 200) + 1}", id)
    {ipv6, world} = primary_ip(world, "ipv6", "2001:db8:#{id}::/64", id)
    {create, world} = action(world, "create_server", id)
    {start, world} = action(world, "start_server", id)

    server =
      fixture("server.json")
      |> Map.merge(%{"id" => id, "name" => body["name"], "labels" => body["labels"]})
      |> put_in(["public_net", "ipv4"], %{
        "id" => ipv4["id"],
        "ip" => ipv4["ip"],
        "blocked" => false,
        "dns_ptr" => ""
      })
      |> put_in(["public_net", "ipv6"], %{
        "id" => ipv6["id"],
        "ip" => ipv6["ip"],
        "blocked" => false,
        "dns_ptr" => []
      })
      |> put_in(["public_net", "firewalls"], firewalls_of(body))

    answer = %{
      "server" => server,
      "action" => create,
      "next_actions" => [start],
      "root_password" => @root_password
    }

    {{201, answer}, put_in(world.servers[id], Map.put(server, "status", "running"))}
  end

  defp firewalls_of(body) do
    for %{"firewall" => id} <- body["firewalls"] || [], do: %{"id" => id, "status" => "applied"}
  end

  defp delete_server(server, world) do
    {action, world} = action(world, "delete_server", server["id"])
    ips = [server["public_net"]["ipv4"]["id"], server["public_net"]["ipv6"]["id"]]
    world = %{world | servers: Map.delete(world.servers, server["id"])}

    world =
      if world.auto_delete_ips,
        do: %{world | primary_ips: Map.drop(world.primary_ips, ips)},
        else: world

    {{200, %{"action" => action}}, world}
  end

  defp applied?(world, firewall_id) do
    Enum.any?(world.servers, fn {_id, server} ->
      Enum.any?(server["public_net"]["firewalls"], &(&1["id"] == firewall_id))
    end)
  end

  defp primary_ip(world, type, ip, server_id) do
    {id, world} = next_id(world)

    record =
      Map.merge(fixture("primary_ip.json"), %{
        "id" => id,
        "name" => "primary_ip-#{id}",
        "type" => type,
        "ip" => ip,
        "auto_delete" => world.auto_delete_ips,
        "assignee_id" => server_id
      })

    {record, put_in(world.primary_ips[id], record)}
  end

  # -- actions ----------------------------------------------------------------

  defp action(world, command, resource_id) do
    {id, world} = next_id(world)

    record =
      Map.merge(fixture("action.json"), %{
        "id" => id,
        "command" => command,
        "resources" => [%{"id" => resource_id, "type" => "server"}]
      })

    state = %{record: record, polls_left: world.action_polls, error: nil}
    {record, put_in(world.actions[id], state)}
  end

  defp poll(id, world) do
    case Map.fetch(world.actions, id) do
      {:ok, %{polls_left: left} = state} when left > 0 ->
        {{200, %{"action" => state.record}}, put_in(world.actions[id].polls_left, left - 1)}

      {:ok, state} ->
        {{200, %{"action" => finished(state)}}, world}

      :error ->
        {error(404, "not_found"), world}
    end
  end

  defp finished(%{record: record, error: nil}),
    do: %{record | "status" => "success", "progress" => 100, "finished" => "2031-05-04T10:01:00Z"}

  defp finished(%{record: record, error: message}),
    do: %{
      record
      | "status" => "error",
        "finished" => "2031-05-04T10:01:00Z",
        "error" => %{"code" => "action_failed", "message" => message}
    }

  # -- listings ---------------------------------------------------------------

  defp one(key, held, id, world) do
    case Map.fetch(held, String.to_integer(id)) do
      {:ok, record} -> {{200, %{key => record}}, world}
      :error -> {error(404, "not_found"), world}
    end
  end

  defp listing(key, held, query) do
    records =
      held
      |> Map.values()
      |> Enum.filter(&selected?(&1["labels"] || %{}, query["label_selector"]))
      |> Enum.sort_by(& &1["id"])

    %{key => records, "meta" => meta(records)}
  end

  defp selected?(_labels, nil), do: true

  defp selected?(labels, selector) do
    selector |> String.split(",") |> Enum.all?(&term?(labels, &1))
  end

  defp term?(labels, "!" <> key), do: not Map.has_key?(labels, key)

  defp term?(labels, term) do
    case String.split(term, "=", parts: 2) do
      [key, value] -> labels[key] == value
      [key] -> Map.has_key?(labels, key)
    end
  end

  defp meta(records),
    do: %{
      "pagination" => %{
        "page" => 1,
        "per_page" => 50,
        "previous_page" => nil,
        "next_page" => nil,
        "last_page" => 1,
        "total_entries" => length(records)
      }
    }

  defp next_id(world), do: {world.next_id, %{world | next_id: world.next_id + 1}}
end
