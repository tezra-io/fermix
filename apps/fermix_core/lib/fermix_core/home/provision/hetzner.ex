defmodule FermixCore.Home.Provision.Hetzner do
  @moduledoc """
  The Hetzner Cloud provider (M75 lean v1 §3, §4.3, L1, L2): an API adapter
  of the `FermixCore.Home.Provision` contract, Req over
  `https://api.hetzner.cloud/v1` with the project token the owner pasted,
  which `Provision.Driver` reads from `device/provision/hetzner.json` and
  passes with each call. It writes no ledger: every primitive is one call (or
  a fixed few) to Hetzner's API, answered as the contract's normalized facts
  and kinds. Every request goes through `Net.HttpClient` (the shared pool and
  the egress proxy), with no automatic retry and no redirect.

  What is Hetzner's lives here only: its endpoints; Fermix's labels encoded
  as Hetzner labels and found again with a `label_selector`; its prices,
  decimal strings ("19.4900000000") read as ten-thousandths; its error codes
  and their kinds; Falkenstein (`fsn1`), Nuremberg (`nbg1`) and Helsinki
  (`hel1`), the places Fermix creates a server in, in that order; its Debian
  13 image (`GET /images?type=system&name=debian-13&architecture=x86`); its
  32 KiB of user data; and its ids, numbers Fermix keeps as their strings.

  The primitives: `check_token/2` (`GET /servers` without Fermix's label,
  `GET /pricing`), `catalog/2` (`GET /server_types`, paged, at most 5 pages;
  `GET /pricing`; `GET /locations`), `server_type/3` (`GET
  /server_types?name=`, `GET /locations`), `system_image/2`,
  `create_firewall/3` (`POST /firewalls` with no rule and nothing applied
  to), `create_server/3` (`POST /servers`: its type and place, the image, the
  firewall, the primary IPv4 kept and IPv6, the labels, no SSH key, the user
  data, started on create; its create and start actions), `power/4` (`POST
  /servers/{id}/actions/poweron` or `reset`), `action/3` (`GET
  /actions/{id}`), `get/4` and `find/4` (`GET /servers`, `/firewalls`,
  `/primary_ips`, by id or by labels) and `delete/4`.

  **The root password.** Hetzner answers a create made with no SSH key with
  the server's root password. It is deleted from every answer where the
  answer arrives (`answer/3`), before anything matches on it, so not even a
  crash report carries it; the driver then keeps only the created server's
  facts.

  **Errors** (`error/1`). `401` is `:unauthorized`; `403 forbidden` a
  read-only token (`:read_only_token`); `403 resource_limit_exceeded` the
  account's limit; `404` `:not_found`; `412 resource_unavailable` no
  capacity (`:no_capacity`); `422 resource_in_use` a firewall its deleted
  server still holds (`:in_use`); `429` rate limited, with Hetzner's
  `RateLimit-Reset`. A write whose outcome is unknown is `{:unknown, _}`: no
  answer, a 5xx, or a `409 uniqueness_error` (the shared pool sends a
  request again once when its connection closed under it, so the first may
  have been carried out). Every other refusal is Hetzner's own message in
  one plain sentence (`{:other, sentence}`). The log names each refusal's
  status and code; the sentence says only the message.
  """

  @behaviour FermixCore.Home.Provision

  alias FermixCore.Home.Provision
  alias FermixCore.Net.HttpClient

  require Logger

  @id "hetzner"
  @base_url "https://api.hetzner.cloud/v1"
  @locations ~w(fsn1 nbg1 hel1)
  @cities %{"fsn1" => "Falkenstein", "nbg1" => "Nuremberg", "hel1" => "Helsinki"}
  @image "debian-13"
  @max_user_data 32_768
  @receive_timeout_ms 10_000
  @max_pages 5
  @max_vendor_bytes 300
  @paths %{server: "/servers", firewall: "/firewalls", primary_ip: "/primary_ips"}
  @steps %{
    "create_server" => :create,
    "start_server" => :start,
    "delete_server" => :delete,
    "poweron_server" => :power_on,
    "reset_server" => :reset
  }

  # -- identity -------------------------------------------------------------------

  @impl true
  def id, do: @id

  @impl true
  def display do
    %{
      name: "Hetzner",
      token_label: "Hetzner API token",
      write_token: "a Read & Write API token",
      account: "project",
      steps: [
        "Sign in to Hetzner's console and turn on two-factor sign-in for your account.",
        "Make a new project for Fermix alone, so the token reaches nothing else.",
        "In that project, open Security, then API Tokens, and generate a token with Read & " <>
          "Write permission.",
        "Paste the token here: Fermix checks it at once."
      ],
      console_url: "https://console.hetzner.cloud/",
      docs_anchor: "hetzner",
      locations: Enum.map(@locations, &%{id: &1, city: Map.fetch!(@cities, &1)}),
      # Its name, the permission and the two places in its console the steps
      # name as it labels them, and its cities.
      proper_nouns: ["Hetzner", "Read & Write", "API Tokens", "Security"] ++ Map.values(@cities)
    }
  end

  # Hetzner's console names a type in capitals ("CPX22").
  @impl true
  def type_name(type) when is_binary(type), do: String.upcase(type)

  @impl true
  def max_user_data, do: @max_user_data

  # -- reads ------------------------------------------------------------------------

  @impl true
  def check_token(token, opts) when is_binary(token) and is_list(opts),
    do: token |> project(opts) |> result()

  defp project(token, opts) do
    with {:ok, %{"servers" => servers}} <-
           http_get(token, "/servers", opts, label_selector: "!fermix", per_page: 1),
         {:ok, _pricing} <- http_get(token, "/pricing", opts) do
      {:ok, %{other_servers: servers != []}}
    end
  end

  @impl true
  def catalog(token, opts) when is_binary(token) and is_list(opts),
    do: token |> priced(opts) |> result()

  defp priced(token, opts) do
    with {:ok, types} <- server_types(token, opts, 1, []),
         {:ok, %{"pricing" => pricing}} <- http_get(token, "/pricing", opts),
         {:ok, %{"locations" => locations}} <- http_get(token, "/locations", opts) do
      {:ok,
       %{
         currency: pricing["currency"],
         locations: Enum.map(locations, &location/1),
         types: Enum.map(types, &type_view/1),
         ipv4_monthly: ipv4_prices(pricing)
       }}
    end
  end

  @impl true
  def server_type(token, type, opts) when is_binary(token) and is_binary(type),
    do: token |> typed(type, opts) |> result()

  defp typed(token, type, opts) do
    with {:ok, %{"server_types" => types}} <- http_get(token, "/server_types", opts, name: type),
         {:ok, %{"locations" => locations}} <- http_get(token, "/locations", opts) do
      found = Enum.find(types, &(&1["name"] == type))
      cities = Map.new(locations, &{&1["name"], &1["city"]})
      {:ok, %{type: found && type_view(found), cities: cities}}
    end
  end

  @impl true
  def system_image(token, opts) when is_binary(token) do
    case http_get(token, "/images", opts, type: "system", name: @image, architecture: "x86") do
      {:ok, %{"images" => [%{"id" => id} | _rest]}} -> {:ok, Integer.to_string(id)}
      {:ok, _none} -> {:error, :no_image}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @impl true
  def action(token, id, opts) when is_binary(token) and is_binary(id) do
    case http_get(token, "/actions/#{id}", opts) do
      {:ok, %{"action" => read}} -> {:ok, action_view(read)}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @impl true
  def get(token, kind, id, opts) when is_map_key(@paths, kind) and is_binary(id) do
    key = Atom.to_string(kind)

    case http_get(token, "#{@paths[kind]}/#{id}", opts) do
      {:ok, %{^key => found}} -> {:ok, resource(kind, found)}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @impl true
  def find(token, kind, labels, opts) when kind in [:server, :firewall] and is_map(labels) do
    key = Atom.to_string(kind) <> "s"

    case http_get(token, @paths[kind], opts, label_selector: selector(labels)) do
      {:ok, %{^key => [found | _rest]}} -> {:ok, resource(kind, found)}
      {:ok, %{^key => []}} -> {:ok, nil}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp server_types(_token, _opts, page, _acc) when page > @max_pages,
    do: {:error, :too_many_types}

  defp server_types(token, opts, page, acc) do
    case http_get(token, "/server_types", opts, per_page: 50, page: page) do
      {:ok, %{"server_types" => types} = body} ->
        case get_in(body, ["meta", "pagination", "next_page"]) do
          next when is_integer(next) -> server_types(token, opts, next, acc ++ types)
          _last -> {:ok, acc ++ types}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # -- writes -----------------------------------------------------------------------

  @impl true
  def create_firewall(token, %{name: name, labels: labels}, opts) when is_binary(token) do
    body = %{name: name, labels: labels, rules: [], apply_to: []}

    case http_post(token, "/firewalls", body, opts) do
      {:ok, %{"firewall" => %{"id" => id}}} -> {:ok, Integer.to_string(id)}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  @impl true
  def create_server(token, spec, opts) when is_binary(token) and is_map(spec) do
    body = %{
      name: spec.name,
      server_type: spec.type,
      location: spec.location,
      image: String.to_integer(spec.image),
      start_after_create: true,
      firewalls: [%{firewall: String.to_integer(spec.firewall)}],
      public_net: %{enable_ipv4: true, enable_ipv6: true},
      labels: spec.labels,
      user_data: spec.user_data
    }

    case http_post(token, "/servers", body, opts) do
      {:ok, answer} -> {:ok, created(answer)}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  # Only the ids, the address, the time and the actions are read; the rest of
  # the answer is dropped here (the root password went at the client's
  # boundary). An answer shaped otherwise fails loud.
  defp created(%{"server" => %{"id" => _id} = server, "action" => action} = answer) do
    server
    |> resource_server()
    |> Map.take([:id, :ipv4, :created_at, :primary_ips])
    |> Map.put(:actions, Enum.map([action | answer["next_actions"] || []], &action_view/1))
  end

  @impl true
  def power(token, id, verb, opts) when is_binary(id) and verb in [:on, :reset] do
    case http_post(token, "/servers/#{id}/actions/#{power_verb(verb)}", %{}, opts) do
      {:ok, %{"action" => started}} -> {:ok, action_view(started)}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  defp power_verb(:on), do: "poweron"
  defp power_verb(:reset), do: "reset"

  @impl true
  def delete(token, kind, id, opts) when is_map_key(@paths, kind) and is_binary(id) do
    case http_delete(token, "#{@paths[kind]}/#{id}", opts) do
      {:ok, %{"action" => started}} -> {:ok, action_view(started)}
      {:ok, _body} -> {:ok, nil}
      {:error, reason} -> {:error, error(reason)}
    end
  end

  # -- Hetzner's shapes, normalized -------------------------------------------------

  defp type_view(type) do
    %{
      name: type["name"],
      description: type["description"],
      cores: type["cores"],
      memory_gb: whole(type["memory"]),
      disk_gb: type["disk"],
      x86: type["architecture"] == "x86",
      sold: type["deprecated"] == false,
      dedicated: type["cpu_type"] == "dedicated",
      stock: for(%{"available" => true, "name" => name} <- type["locations"] || [], do: name),
      monthly: prices(type["prices"] || [])
    }
  end

  defp prices(prices) do
    for %{"location" => location, "price_monthly" => %{"gross" => gross}} <- prices,
        into: %{},
        do: {location, units(gross)}
  end

  defp ipv4_prices(pricing) do
    case Enum.find(pricing["primary_ips"] || [], &(&1["type"] == "ipv4")) do
      %{"prices" => prices} -> prices(prices)
      _none -> %{}
    end
  end

  defp location(location),
    do: %{id: location["name"], city: location["city"], country: location["country"]}

  defp resource(:server, server), do: resource_server(server)
  defp resource(_kind, %{"id" => id}), do: %{id: Integer.to_string(id)}

  defp resource_server(server) do
    %{
      id: Integer.to_string(server["id"]),
      power: server["status"],
      ipv4: get_in(server, ["public_net", "ipv4", "ip"]),
      created_at: time(server["created"]),
      primary_ips: primary_ips(server)
    }
  end

  defp primary_ips(server) do
    for type <- ["ipv4", "ipv6"],
        %{"id" => id} = ip <- [get_in(server, ["public_net", type])],
        do: %{id: Integer.to_string(id), type: type, ip: ip["ip"]}
  end

  defp action_view(%{"id" => id, "status" => status, "command" => command} = action) do
    %{
      id: Integer.to_string(id),
      status: action_status(status),
      step: Map.get(@steps, command, :other),
      message: if(status == "error", do: action_message(action["error"]))
    }
  end

  defp action_status("success"), do: :success
  defp action_status("error"), do: :error
  defp action_status(_running), do: :running

  defp action_message(error), do: bounded((error || %{})["message"] || "Hetzner gave no reason.")

  # Fermix's labels as Hetzner's label selector.
  defp selector(labels),
    do: labels |> Enum.sort() |> Enum.map_join(",", fn {key, value} -> "#{key}=#{value}" end)

  # Hetzner writes prices as decimal strings ("19.4900000000"); a ten
  # thousandth of a unit is exact for every price it sells.
  defp units(text) when is_binary(text) do
    [whole | rest] = String.split(text, ".", parts: 2)
    fraction = rest |> List.first("") |> String.pad_trailing(4, "0") |> binary_part(0, 4)
    String.to_integer(whole) * 10_000 + String.to_integer(fraction)
  end

  defp whole(memory) when is_float(memory) and memory == trunc(memory), do: trunc(memory)
  defp whole(memory), do: memory

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      _invalid -> nil
    end
  end

  defp time(_text), do: nil

  # -- the kinds --------------------------------------------------------------------

  defp result({:error, reason}), do: {:error, error(reason)}
  defp result(answer), do: answer

  @doc """
  One of Hetzner's own refusals as the kind its primitives answer
  (`Provision.error/0`): a shared kind, one the driver reads, an outcome it
  cannot know (`{:unknown, _}`), or Hetzner's own message in a plain
  sentence (`{:other, sentence}`).
  """
  @spec error(term()) :: Provision.error()
  def error(:forbidden), do: :read_only_token
  def error(:resource_in_use), do: :in_use
  def error(:resource_unavailable), do: :no_capacity
  def error({:unreachable, _message} = reason), do: {:unknown, reason}

  def error({:refused, status, _code, _message} = refused) when status >= 500,
    do: {:unknown, refused_sentence(refused)}

  def error({:refused, 409, "uniqueness_error", _message} = refused),
    do: {:unknown, refused_sentence(refused)}

  def error({:refused, _status, _code, _message} = refused), do: refused_sentence(refused)

  def error(:too_many_types),
    do:
      {:other, "Hetzner listed more server types than Fermix reads, so it offers none right now."}

  def error(reason), do: reason

  defp refused_sentence({:refused, _status, _code, message}),
    do: {:other, "Hetzner refused the request: #{Provision.plain(message)}"}

  # -- the client -------------------------------------------------------------------

  defp http_get(token, path, opts, params \\ []),
    do: request(token, :get, path, opts, params: params)

  defp http_post(token, path, body, opts), do: request(token, :post, path, opts, json: body)
  defp http_delete(token, path, opts), do: request(token, :delete, path, opts, [])

  defp request(token, method, path, opts, extra) do
    [
      method: method,
      base_url: @base_url,
      url: path,
      auth: {:bearer, token},
      retry: false,
      redirect: false,
      receive_timeout: @receive_timeout_ms
    ]
    |> Kernel.++(extra)
    |> Req.new()
    |> Req.merge(Keyword.get(opts, :req_options, []))
    |> HttpClient.request("Hetzner #{method |> Atom.to_string() |> String.upcase()} #{path}")
    |> answer(method, path)
  end

  # The root password Hetzner answers a create with goes no further than
  # here, before anything matches on the answer: not even a crash report
  # carries it.
  defp answer({:ok, %Req.Response{status: status, body: %{} = body}}, _method, _path)
       when status in 200..299,
       do: {:ok, Map.delete(body, "root_password")}

  defp answer({:ok, %Req.Response{status: status, body: body}}, _method, _path)
       when status in 200..299,
       do: {:ok, body}

  # The status and Hetzner's code go to the log: the sentence a refusal
  # becomes carries neither (`error/1`).
  defp answer({:ok, %Req.Response{status: status} = response}, method, path) do
    code = vendor(response.body, "code") || "no code"
    Logger.warning("provision: Hetzner answered #{method} #{path} with #{status} (#{code})")
    {:error, refusal(status, response)}
  end

  defp answer({:error, exception}, method, path) do
    message = bounded(Exception.message(exception))
    Logger.warning("provision: Hetzner #{method} #{path} did not answer: #{message}")
    {:error, {:unreachable, message}}
  end

  # Hetzner's error codes answered by name; any other refusal keeps
  # Hetzner's own code and message.
  @named_refusals %{
    {403, "resource_limit_exceeded"} => :account_limit,
    {403, "forbidden"} => :forbidden,
    {412, "resource_unavailable"} => :resource_unavailable,
    {422, "resource_in_use"} => :resource_in_use
  }

  defp refusal(401, _response), do: :unauthorized
  defp refusal(404, _response), do: :not_found
  defp refusal(429, response), do: {:rate_limited, reset(response)}

  defp refusal(status, %Req.Response{body: body}) do
    code = vendor(body, "code")

    Map.get_lazy(@named_refusals, {status, code}, fn ->
      message = vendor(body, "message") || "Hetzner gave no message."
      {:refused, status, code || "no_code", bounded(message)}
    end)
  end

  defp vendor(%{"error" => %{} = error}, key) do
    case error[key] do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp vendor(_body, _key), do: nil

  defp reset(response) do
    case Req.Response.get_header(response, "ratelimit-reset") do
      [value | _rest] -> parse_int(value)
      [] -> nil
    end
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp bounded(text) when is_binary(text) do
    text
    |> String.replace(~r/[\x{0000}-\x{001F}\x{007F}]/u, " ")
    |> String.slice(0, @max_vendor_bytes)
    |> String.trim()
  end
end
