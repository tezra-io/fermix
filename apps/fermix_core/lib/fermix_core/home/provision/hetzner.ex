defmodule FermixCore.Home.Provision.Hetzner do
  @moduledoc """
  The Hetzner Cloud host (M75 lean v1 §3, §4.3, L1, L2): Req over
  `https://api.hetzner.cloud/v1` with the project token the owner pasted, kept
  in `Provision.Ledger`'s `device/provision/hetzner.json`. Every request goes
  through `Net.HttpClient` (the shared pool and the egress proxy), with no
  automatic retry and no redirect.

  **Options (L2).** `GET /server_types` (shape, per-location stock in
  `locations[].available`, and prices), `GET /pricing` (the currency and the
  IPv4 address's price) and `GET /locations` (the city names), read live and
  never written into the engine. Offered: every type that is x86, has at
  least 4 GB and is not deprecated, in Falkenstein (`fsn1`), Nuremberg
  (`nbg1`) and Helsinki (`hel1`), wherever it is in stock, at the gross
  monthly price, VAT included as the account is billed, plus the IPv4
  address's. Recommended: the cheapest such type, in the first of the three
  where it is in stock; "more room": the cheapest type with more memory,
  where the recommendation is or else the first place it is in stock.

  **Create.** The type and location are checked against the live stock
  first (`GET /server_types?name=`, `GET /locations`), so a type sold out
  there is refused before anything is written, naming the next location in
  stock. Then, each written to the ledger before its call and after it: the
  firewall with no inbound rule (`POST /firewalls`, the first write, where a
  read-only token is refused before anything costs money); the Debian 13
  image (`GET /images?type=system&name=debian-13&architecture=x86`); a fresh
  provisioned enrollment code (24 hours, L15); and the server (`POST
  /servers`): its name and labels from the ledger's ref, the firewall, the
  primary IPv4 kept (and IPv6), no SSH key, and the first boot with the code
  as user data. Its create and start actions are polled (`GET /actions/{id}`,
  every 2 s, at most 150 times each); then `GET /servers/{id}` records it
  running. A create that stopped after its firewall stood reuses that
  firewall and the ledger's ref on the next try. A `POST` refused outright
  leaves nothing behind (its code withdrawn); one whose answer did not come
  (no connection, a 5xx) stays `requested` in the ledger and keeps its code,
  and `reconcile/2` finds it by its labels.

  **The root password.** Hetzner answers a create made with no SSH key with
  the server's root password. The answer is read for its ids and dropped:
  nothing of it reaches the ledger, a log, a trace or a status.

  **Errors.** `401` is `:unauthorized`; `403 forbidden` on a write a
  read-only token (`:forbidden`); `403 resource_limit_exceeded` the
  account's limit; `412 resource_unavailable` no capacity, with the next
  location in stock; `429` rate limited, with Hetzner's `RateLimit-Reset`
  (a poll waits 10 s and goes on, still counted against its bound); every
  other refusal carries Hetzner's own code and message.
  """

  @behaviour FermixCore.Home.Provision

  alias FermixCore.Home.Provision
  alias FermixCore.Home.Provision.FirstBoot
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Net.HttpClient

  require Logger

  @host "hetzner"
  @base_url "https://api.hetzner.cloud/v1"
  @locations ~w(fsn1 nbg1 hel1)
  @min_memory_gb 4
  @poll_ms 2_000
  @max_polls 150
  @rate_wait_ms 10_000
  @in_use_tries 10
  @receive_timeout_ms 10_000
  @max_pages 5
  @max_vendor_bytes 300

  @impl true
  def host, do: @host

  @doc "The three locations Fermix offers, in the order it recommends them."
  @spec locations() :: [String.t()]
  def locations, do: @locations

  # -- the token ----------------------------------------------------------------

  @impl true
  def check_token(token, opts) when is_binary(token) and is_list(opts) do
    with {:ok, %{"servers" => servers}} <-
           get(token, "/servers", opts, label_selector: "!fermix", per_page: 1),
         {:ok, _pricing} <- get(token, "/pricing", opts) do
      {:ok, %{other_servers: servers != []}}
    end
  end

  # One read by id, with the new token, of what the ledger holds: Hetzner
  # answers 404 for a resource of another project.
  @impl true
  def reaches(token, ledger, opts) when is_binary(token) and is_map(ledger) do
    case standing(ledger) do
      nil -> :ok
      path -> reached(get(token, path, opts))
    end
  end

  defp standing(%{server: %{id: id, status: status}}) when is_integer(id) and status != :gone,
    do: "/servers/#{id}"

  defp standing(%{firewall: %{id: id, status: status}}) when is_integer(id) and status != :gone,
    do: "/firewalls/#{id}"

  defp standing(_ledger), do: nil

  defp reached({:ok, _found}), do: :ok
  defp reached({:error, :not_found}), do: {:error, :other_project}
  defp reached({:error, _reason} = error), do: error

  # -- options ------------------------------------------------------------------

  @impl true
  def options(token, opts) when is_binary(token) and is_list(opts) do
    with {:ok, types} <- server_types(token, opts),
         {:ok, %{"pricing" => pricing}} <- get(token, "/pricing", opts),
         {:ok, %{"locations" => locations}} <- get(token, "/locations", opts) do
      {:ok, offering(types, pricing, locations)}
    end
  end

  defp server_types(token, opts), do: server_types(token, opts, 1, [])

  defp server_types(_token, _opts, page, _acc) when page > @max_pages,
    do: {:error, :too_many_types}

  defp server_types(token, opts, page, acc) do
    case get(token, "/server_types", opts, per_page: 50, page: page) do
      {:ok, %{"server_types" => types} = body} ->
        case get_in(body, ["meta", "pagination", "next_page"]) do
          next when is_integer(next) -> server_types(token, opts, next, acc ++ types)
          _last -> {:ok, acc ++ types}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  # Pure: the offers, the recommendation and "more room" from the three
  # answers. Public for the tests of the L2 rule.
  @spec offering([map()], map(), [map()]) :: map()
  def offering(types, pricing, locations) do
    ipv4 = ipv4_prices(pricing)

    offers =
      types |> Enum.filter(&eligible?/1) |> Enum.flat_map(&offers(&1, ipv4)) |> sort_offers()

    recommended = recommend(offers)

    %{
      "currency" => pricing["currency"],
      "locations" => location_views(locations),
      "offers" => offers,
      "recommended" => recommended && pick(recommended),
      "more_room" => more_room(offers, recommended)
    }
  end

  defp eligible?(type) do
    type["architecture"] == "x86" and type["deprecated"] == false and
      is_number(type["memory"]) and type["memory"] >= @min_memory_gb
  end

  defp offers(type, ipv4) do
    for location <- @locations,
        in_stock?(type, location),
        {:ok, monthly} <- [monthly(type, location)] do
      address = Map.get(ipv4, location, 0)

      %{
        "type" => type["name"],
        "description" => type["description"],
        "cores" => type["cores"],
        "memory_gb" => whole(type["memory"]),
        "disk_gb" => type["disk"],
        "dedicated" => type["cpu_type"] == "dedicated",
        "location" => location,
        "monthly" => money(monthly),
        "ipv4_monthly" => money(address),
        "total_monthly" => money(monthly + address)
      }
    end
  end

  defp in_stock?(type, location),
    do: Enum.any?(type["locations"] || [], &(&1["name"] == location and &1["available"] == true))

  defp monthly(type, location) do
    case Enum.find(type["prices"] || [], &(&1["location"] == location)) do
      %{"price_monthly" => %{"gross" => gross}} -> {:ok, units(gross)}
      _none -> :error
    end
  end

  defp ipv4_prices(pricing) do
    case Enum.find(pricing["primary_ips"] || [], &(&1["type"] == "ipv4")) do
      %{"prices" => prices} ->
        Map.new(prices, &{&1["location"], units(&1["price_monthly"]["gross"])})

      _none ->
        %{}
    end
  end

  # Cheapest first; among equals, in the order of the three locations.
  defp sort_offers(offers),
    do: Enum.sort_by(offers, &{units(&1["total_monthly"]), location_rank(&1["location"])})

  defp location_rank(location), do: Enum.find_index(@locations, &(&1 == location))

  # The cheapest type, in the first location where it is in stock.
  defp recommend([]), do: nil

  defp recommend([cheapest | _rest] = offers) do
    offers
    |> Enum.filter(&(&1["type"] == cheapest["type"]))
    |> Enum.min_by(&location_rank(&1["location"]))
  end

  defp more_room(_offers, nil), do: nil

  defp more_room(offers, recommended) do
    bigger = Enum.filter(offers, &(&1["memory_gb"] > recommended["memory_gb"]))

    case bigger do
      [] ->
        nil

      [next | _rest] ->
        same_type = Enum.filter(bigger, &(&1["type"] == next["type"]))
        here = Enum.find(same_type, &(&1["location"] == recommended["location"]))
        pick(here || Enum.min_by(same_type, &location_rank(&1["location"])))
    end
  end

  defp pick(offer), do: %{"type" => offer["type"], "location" => offer["location"]}

  defp location_views(locations) do
    for id <- @locations, %{} = location <- [Enum.find(locations, &(&1["name"] == id))] do
      %{"id" => id, "city" => location["city"], "country" => location["country"]}
    end
  end

  # Hetzner writes prices as decimal strings ("19.4900000000"); a ten
  # thousandth of a unit is exact for every price it sells.
  defp units(text) when is_binary(text) do
    [whole | rest] = String.split(text, ".", parts: 2)
    fraction = rest |> List.first("") |> String.pad_trailing(4, "0") |> binary_part(0, 4)
    String.to_integer(whole) * 10_000 + String.to_integer(fraction)
  end

  defp money(units) when is_integer(units) do
    cents = div(units + 50, 100)
    "#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp whole(memory) when is_float(memory) and memory == trunc(memory), do: trunc(memory)
  defp whole(memory), do: memory

  # -- create -------------------------------------------------------------------

  @impl true
  def create(home, %{type: type, location: location, profile: profile}, opts)
      when is_binary(home) and is_binary(type) and location in @locations and is_binary(profile) do
    report(opts, "checking")

    with {:ok, ledger} <- read(home),
         {:ok, token} <- token(ledger),
         :ok <- no_server(ledger),
         {:ok, facts} <- checked(token, type, location, opts),
         {:ok, plan} <- begin(home, ledger, facts, profile),
         {:ok, firewall_id} <- firewall(home, token, plan, opts),
         {:ok, image_id} <- image(token, opts),
         {:ok, user_data} <- user_data(opts),
         {:ok, created} <-
           server(
             home,
             token,
             plan,
             %{firewall: firewall_id, image: image_id, user_data: user_data},
             opts
           ) do
      started(home, token, created, opts)
    end
  end

  defp no_server(%{server: %{status: status}}) when status != :gone, do: {:error, :server_exists}
  defp no_server(_ledger), do: :ok

  # The type as Hetzner sells it now, and the city names, before anything is
  # written: a type sold out where asked is refused with the next location in
  # stock.
  defp checked(token, type, location, opts) do
    with {:ok, %{"server_types" => types}} <- get(token, "/server_types", opts, name: type),
         {:ok, %{"locations" => locations}} <- get(token, "/locations", opts),
         {:ok, found} <- eligible(types, type) do
      facts = %{
        type: type,
        description: found["description"],
        location: location,
        city: city(locations, location),
        stock: Enum.filter(@locations, &in_stock?(found, &1)),
        cities: Map.new(@locations, &{&1, city(locations, &1)})
      }

      if location in facts.stock, do: {:ok, facts}, else: {:error, unavailable(facts)}
    end
  end

  defp eligible(types, type) do
    case Enum.find(types, &(&1["name"] == type)) do
      %{} = found ->
        if eligible?(found), do: {:ok, found}, else: {:error, {:ineligible_type, type}}

      nil ->
        {:error, {:ineligible_type, type}}
    end
  end

  defp city(locations, id) do
    case Enum.find(locations, &(&1["name"] == id)) do
      %{"city" => city} when is_binary(city) -> city
      _unknown -> id
    end
  end

  defp unavailable(facts) do
    next = Enum.find(facts.stock, &(&1 != facts.location))

    {:unavailable,
     %{
       type: facts.type,
       description: facts.description,
       location: facts.location,
       city: facts.city,
       next: next,
       next_city: next && facts.cities[next]
     }}
  end

  # A create that stopped after its firewall stood keeps that firewall and the
  # ledger's ref; any other starts afresh with a new ref.
  defp begin(home, ledger, facts, profile) do
    {ref, reuse} =
      case ledger do
        %{ref: ref, firewall: %{status: :created, id: id}} when is_binary(ref) -> {ref, id}
        _fresh -> {fresh_ref(), nil}
      end

    plan =
      Map.merge(facts, %{
        ref: ref,
        profile: profile,
        name: Provision.server_name(profile, ref),
        reuse_firewall: reuse
      })

    transform =
      if reuse,
        do: &%{&1 | failure: nil, server: nil},
        else: &Ledger.begin_create(&1, ref, %{name: plan.name})

    with {:ok, _ledger} <- update(home, &{:ok, transform.(&1)}), do: {:ok, plan}
  end

  defp fresh_ref, do: 2 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp firewall(_home, _token, %{reuse_firewall: id}, _opts) when is_integer(id), do: {:ok, id}

  defp firewall(home, token, plan, opts) do
    report(opts, "firewall")

    body = %{
      name: plan.name,
      labels: Provision.labels(plan.profile, plan.ref),
      rules: [],
      apply_to: []
    }

    case post(token, "/firewalls", body, opts) do
      {:ok, %{"firewall" => %{"id" => id}}} ->
        with {:ok, _ledger} <-
               update(home, &{:ok, Ledger.put_firewall(&1, %{id: id, status: :created})}),
             do: {:ok, id}

      {:error, reason} ->
        forget_if_refused(home, :firewall, reason)
    end
  end

  defp image(token, opts) do
    case get(token, "/images", opts, type: "system", name: "debian-13", architecture: "x86") do
      {:ok, %{"images" => [%{"id" => id} | _rest]}} -> {:ok, id}
      {:ok, _none} -> {:error, :no_image}
      {:error, _reason} = error -> error
    end
  end

  defp user_data(opts) do
    with {:ok, code} <- open_code(opts) do
      case FirstBoot.user_data(code) do
        {:ok, user_data} -> {:ok, user_data}
        {:error, :too_large} -> withdrawn(opts, :user_data_too_large)
        {:error, :invalid_code} -> withdrawn(opts, :invalid_code)
      end
    end
  end

  defp open_code(opts) do
    case Keyword.fetch!(opts, :open_code).() do
      {:ok, code} -> {:ok, code}
      {:error, sentence} when is_binary(sentence) -> {:error, {:code_unavailable, sentence}}
    end
  end

  defp withdraw_code(opts) do
    case Keyword.fetch!(opts, :withdraw_code).() do
      :ok -> :ok
      {:error, {:unavailable, sentence}} -> {:error, {:code_unavailable, sentence}}
    end
  end

  # The code of a server that will not exist is withdrawn; the create's own
  # reason is the answer, and a code that could not be withdrawn is logged
  # beside it (it expires by itself).
  defp withdrawn(opts, reason) do
    case withdraw_code(opts) do
      :ok ->
        {:error, reason}

      {:error, {:code_unavailable, sentence}} ->
        Logger.error("provision: the server's enrollment code stays open: #{sentence}")
        {:error, reason}
    end
  end

  defp server(home, token, plan, parts, opts) do
    report(opts, "server")
    asked = %{name: plan.name, type: plan.type, location: plan.location, status: :requested}

    with {:ok, _ledger} <- update(home, &{:ok, Ledger.put_server(&1, asked)}) do
      case post(token, "/servers", server_body(plan, parts), opts) do
        {:ok, answer} -> created(home, answer)
        {:error, reason} -> server_refused(home, plan, reason, opts)
      end
    end
  end

  defp server_body(plan, parts) do
    %{
      name: plan.name,
      server_type: plan.type,
      location: plan.location,
      image: parts.image,
      start_after_create: true,
      firewalls: [%{firewall: parts.firewall}],
      public_net: %{enable_ipv4: true, enable_ipv6: true},
      labels: Provision.labels(plan.profile, plan.ref),
      user_data: parts.user_data
    }
  end

  # Only the ids and the address are read; the rest of the answer is dropped
  # here (the root password went at the client's boundary).
  defp created(home, %{"server" => %{"id" => id} = server, "action" => action} = answer) do
    ips = primary_ips(server)

    facts = %{
      id: id,
      status: :creating,
      ipv4: get_in(server, ["public_net", "ipv4", "ip"]),
      created_at: time(server["created"])
    }

    with {:ok, _ledger} <-
           update(home, &{:ok, &1 |> Ledger.put_server(facts) |> Ledger.put_primary_ips(ips)}) do
      {:ok, %{id: id, actions: [action | answer["next_actions"] || []]}}
    end
  end

  defp primary_ips(server) do
    for type <- ["ipv4", "ipv6"],
        %{"id" => id} = ip <- [get_in(server, ["public_net", type])],
        do: %{id: id, type: type, ip: ip["ip"]}
  end

  defp server_refused(home, plan, reason, opts) do
    if definitive?(reason) do
      with {:ok, _ledger} <- update(home, &{:ok, Ledger.remove(&1, :server)}),
           do: withdrawn(opts, named_refusal(reason, plan))
    else
      {:error, reason}
    end
  end

  defp named_refusal(:resource_unavailable, plan), do: unavailable(plan)
  defp named_refusal(reason, _plan), do: reason

  defp started(home, token, %{id: id, actions: actions}, opts) do
    report(opts, "starting")

    with :ok <- await_all(token, actions, opts),
         {:ok, %{"server" => server}} <- get(token, "/servers/#{id}", opts),
         {:ok, ledger} <-
           update(home, &{:ok, Ledger.put_server(&1, seen(server, :created, opts))}) do
      {:ok, ledger.server}
    end
  end

  defp seen(server, status, opts),
    do: %{status: status, power: server["status"], seen_at: now(opts)}

  # -- power ----------------------------------------------------------------------

  @impl true
  def power(home, action, opts) when is_binary(home) and action in [:on, :reset] do
    report(opts, "power")

    with {:ok, ledger} <- read(home),
         {:ok, token} <- token(ledger),
         {:ok, id} <- server_id(ledger),
         {:ok, %{"action" => started}} <-
           post(token, "/servers/#{id}/actions/#{verb(action)}", %{}, opts),
         :ok <- await_all(token, [started], opts),
         {:ok, %{"server" => server}} <- get(token, "/servers/#{id}", opts),
         {:ok, _ledger} <-
           update(
             home,
             &{:ok, Ledger.put_server(&1, %{power: server["status"], seen_at: now(opts)})}
           ) do
      :ok
    end
  end

  defp verb(:on), do: "poweron"
  defp verb(:reset), do: "reset"

  defp server_id(%{server: %{status: :created, id: id}}) when is_integer(id), do: {:ok, id}
  defp server_id(_ledger), do: {:error, :no_server}

  # -- reconcile ------------------------------------------------------------------

  @impl true
  def reconcile(home, opts) when is_binary(home) and is_list(opts) do
    with {:ok, ledger} <- read(home),
         {:ok, token} <- token(ledger) do
      if Keyword.get(opts, :running?, false),
        do: {:ok, ledger},
        else: reconciled(home, token, ledger, opts)
    end
  end

  defp reconciled(home, token, ledger, opts) do
    with {:ok, server} <- observe_server(token, ledger, opts),
         {:ok, firewall} <- observe_firewall(token, ledger, opts),
         {:ok, changed} <-
           update(home, &{:ok, apply_observed(&1, ledger, {server, firewall}, opts)}),
         :ok <- withdraw_unborn(ledger, server, opts) do
      {:ok, changed}
    end
  end

  # A server asked for whose create never reached Hetzner will not enroll.
  defp withdraw_unborn(%{server: %{id: nil}}, :absent, opts), do: withdraw_code(opts)
  defp withdraw_unborn(_ledger, _observed, _opts), do: :ok

  defp observe_server(_token, %{server: nil}, _opts), do: {:ok, :unchanged}
  defp observe_server(_token, %{server: %{status: :gone}}, _opts), do: {:ok, :unchanged}

  defp observe_server(token, %{server: %{id: nil}} = ledger, opts),
    do: by_labels(token, "/servers", "servers", ledger, opts)

  defp observe_server(token, %{server: %{id: id}}, opts),
    do: by_id(token, "/servers/#{id}", "server", opts)

  defp observe_firewall(_token, %{firewall: nil}, _opts), do: {:ok, :unchanged}
  defp observe_firewall(_token, %{firewall: %{status: :gone}}, _opts), do: {:ok, :unchanged}

  defp observe_firewall(token, %{firewall: %{id: nil}} = ledger, opts),
    do: by_labels(token, "/firewalls", "firewalls", ledger, opts)

  defp observe_firewall(token, %{firewall: %{id: id}}, opts),
    do: by_id(token, "/firewalls/#{id}", "firewall", opts)

  defp by_id(token, path, key, opts) do
    case get(token, path, opts) do
      {:ok, %{^key => found}} -> {:ok, {:found, found}}
      {:error, :not_found} -> {:ok, :absent}
      {:error, _reason} = error -> error
    end
  end

  defp by_labels(token, path, key, ledger, opts) do
    case get(token, path, opts, label_selector: selector(ledger)) do
      {:ok, %{^key => [found | _rest]}} -> {:ok, {:found, found}}
      {:ok, %{^key => []}} -> {:ok, :absent}
      {:error, _reason} = error -> error
    end
  end

  # The labels a create of the ledger's ref put on everything it made; the
  # profile's label is the middle of the name it gave them.
  defp selector(%{ref: ref} = ledger) do
    name = (ledger.server || ledger.firewall).name

    profile =
      name |> String.replace_prefix("fermix-", "") |> String.replace_suffix("-" <> ref, "")

    "fermix=always-on,fermix-profile=#{profile},fermix-ref=#{ref}"
  end

  # Applied to the ledger as it is now, and only where it still names what
  # was read, so a change written meanwhile is never undone.
  defp apply_observed(current, read, {server, firewall}, opts) do
    current
    |> apply_server(read.server, server, opts)
    |> apply_firewall(read.firewall, firewall)
  end

  defp apply_server(current, _read, :unchanged, _opts), do: current

  # Absent from Hetzner: never created (no id), deleted by a delete that
  # stopped before it recorded so (no job runs while this is read), or
  # deleted outside Fermix.
  defp apply_server(%{server: %{id: nil}} = current, %{id: nil}, :absent, opts),
    do: interrupted(current, opts)

  defp apply_server(%{server: %{id: id, status: :deleting}} = current, %{id: id}, :absent, _opts),
    do: Ledger.remove(current, :server)

  defp apply_server(%{server: %{id: id}} = current, %{id: id}, :absent, _opts),
    do: Ledger.put_server(current, %{status: :gone})

  defp apply_server(%{server: %{id: id}} = current, %{id: id}, {:found, found}, opts) do
    status = if found["status"] in ["running", "off"], do: :created, else: :creating

    facts =
      Map.merge(seen(found, status, opts), %{
        id: found["id"],
        ipv4: get_in(found, ["public_net", "ipv4", "ip"]),
        created_at: time(found["created"])
      })

    current |> Ledger.put_server(facts) |> recovered(id, found)
  end

  defp apply_server(current, _read, _observed, _opts), do: current

  # A lost create found again stands: its addresses are recorded, and the
  # failure its lost answer left goes.
  defp recovered(ledger, nil, found),
    do: ledger |> Ledger.put_primary_ips(primary_ips(found)) |> Ledger.put_failure(nil)

  defp recovered(ledger, _id, _found), do: ledger

  # Nothing was created: the server leaves the ledger, and a create that
  # recorded no reason of its own stopped before it was done.
  defp interrupted(current, opts) do
    failure =
      current.failure ||
        %{
          reason: "interrupted",
          sentence: Provision.error_sentence(:interrupted),
          next_location: nil,
          at: now(opts)
        }

    current |> Ledger.remove(:server) |> Ledger.put_failure(failure)
  end

  defp apply_firewall(current, _read, :unchanged), do: current

  defp apply_firewall(%{firewall: %{id: id, status: status}} = current, %{id: id}, :absent)
       when id == nil or status == :deleting,
       do: Ledger.remove(current, :firewall)

  defp apply_firewall(%{firewall: %{id: id}} = current, %{id: id}, :absent),
    do: Ledger.put_firewall(current, %{status: :gone})

  defp apply_firewall(%{firewall: %{id: id}} = current, %{id: id}, {:found, found}),
    do: Ledger.put_firewall(current, %{id: found["id"], status: :created})

  defp apply_firewall(current, _read, _observed), do: current

  # -- delete ---------------------------------------------------------------------

  @impl true
  def delete(home, opts) when is_binary(home) and is_list(opts) do
    with {:ok, ledger} <- read(home),
         {:ok, token} <- token(ledger),
         :ok <- something(ledger) do
      report(opts, "deleting")

      with :ok <- withdraw_code(opts),
           :ok <- delete_server(home, token, ledger, opts),
           :ok <- delete_ips(token, ledger.primary_ips, opts),
           :ok <- delete_firewall(home, token, ledger, opts),
           {:ok, _ledger} <- update(home, &{:ok, Ledger.clear(&1)}) do
        :ok
      end
    end
  end

  defp something(%{server: nil, firewall: nil, primary_ips: [], ref: nil}),
    do: {:error, :nothing_to_delete}

  defp something(_ledger), do: :ok

  defp delete_server(_home, _token, %{server: nil}, _opts), do: :ok

  defp delete_server(home, _token, %{server: %{status: :gone}}, _opts),
    do: forgotten(home, :server)

  defp delete_server(home, token, %{server: %{id: nil}} = ledger, opts) do
    case by_labels(token, "/servers", "servers", ledger, opts) do
      {:ok, {:found, %{"id" => id}}} ->
        delete_server(home, token, put_in(ledger.server.id, id), opts)

      {:ok, :absent} ->
        forgotten(home, :server)

      {:error, _reason} = error ->
        error
    end
  end

  defp delete_server(home, token, %{server: %{id: id}}, opts) do
    with {:ok, _ledger} <-
           update(home, &{:ok, Ledger.put_server(&1, %{id: id, status: :deleting})}),
         :ok <- server_deleted(token, id, opts) do
      forgotten(home, :server)
    end
  end

  # A server already gone from Hetzner is as good as deleted.
  defp server_deleted(token, id, opts) do
    case http_delete(token, "/servers/#{id}", opts) do
      {:ok, %{"action" => action}} -> await_all(token, [action], opts)
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp forgotten(home, kind) do
    with {:ok, _ledger} <- update(home, &{:ok, Ledger.remove(&1, kind)}), do: :ok
  end

  # An address that went with its server answers 404; one that stayed is
  # deleted.
  defp delete_ips(token, ips, opts) do
    Enum.reduce_while(ips, :ok, fn %{id: id}, :ok ->
      case delete_ip(token, id, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_ip(token, id, opts) do
    case get(token, "/primary_ips/#{id}", opts) do
      {:ok, _ip} -> gone_ok(http_delete(token, "/primary_ips/#{id}", opts))
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp gone_ok({:ok, _body}), do: :ok
  defp gone_ok({:error, :not_found}), do: :ok
  defp gone_ok({:error, _reason} = error), do: error

  defp delete_firewall(_home, _token, %{firewall: nil}, _opts), do: :ok

  defp delete_firewall(home, _token, %{firewall: %{status: :gone}}, _opts),
    do: forgotten(home, :firewall)

  defp delete_firewall(home, token, %{firewall: %{id: nil}} = ledger, opts) do
    case by_labels(token, "/firewalls", "firewalls", ledger, opts) do
      {:ok, {:found, %{"id" => id}}} ->
        delete_firewall(home, token, put_in(ledger.firewall.id, id), opts)

      {:ok, :absent} ->
        forgotten(home, :firewall)

      {:error, _reason} = error ->
        error
    end
  end

  defp delete_firewall(home, token, %{firewall: %{id: id}}, opts) do
    with {:ok, _ledger} <- update(home, &{:ok, Ledger.put_firewall(&1, %{status: :deleting})}),
         :ok <- delete_firewall_tries(token, id, opts, @in_use_tries) do
      forgotten(home, :firewall)
    end
  end

  # Hetzner detaches a deleted server's firewall a moment after the server's
  # action ends; until then the firewall answers `resource_in_use`.
  defp delete_firewall_tries(_token, _id, _opts, 0), do: {:error, :resource_in_use}

  defp delete_firewall_tries(token, id, opts, tries) do
    case http_delete(token, "/firewalls/#{id}", opts) do
      {:ok, _body} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, :resource_in_use} ->
        paused(opts, @poll_ms, fn -> delete_firewall_tries(token, id, opts, tries - 1) end)

      {:error, _reason} = error ->
        error
    end
  end

  # -- actions ------------------------------------------------------------------

  defp await_all(token, actions, opts) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case await(token, action, opts, Keyword.get(opts, :max_polls, @max_polls)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp await(_token, %{"status" => "success"}, _opts, _polls), do: :ok
  defp await(_token, %{"status" => "error"} = action, _opts, _polls), do: action_failed(action)
  defp await(_token, %{"command" => command}, _opts, 0), do: {:error, {:action_timeout, command}}

  defp await(token, %{"id" => id} = action, opts, polls) do
    paused(opts, @poll_ms, fn -> poll(token, action, id, opts, polls) end)
  end

  # A rate-limited read waits longer, and a read that got no answer is tried
  # again; both count against the bound.
  defp poll(token, action, id, opts, polls) do
    case get(token, "/actions/#{id}", opts) do
      {:ok, %{"action" => read}} ->
        await(token, read, opts, polls - 1)

      {:error, {:rate_limited, _reset}} ->
        paused(opts, @rate_wait_ms, fn -> await(token, action, opts, polls - 1) end)

      {:error, reason} ->
        if definitive?(reason), do: {:error, reason}, else: await(token, action, opts, polls - 1)
    end
  end

  defp action_failed(%{"command" => command, "error" => error}) do
    message = bounded((error || %{})["message"] || "Hetzner gave no reason.")
    {:error, {:action_failed, command, message}}
  end

  defp paused(opts, ms, next) do
    Keyword.get(opts, :sleep, &Process.sleep/1).(ms)
    next.()
  end

  # -- the client -----------------------------------------------------------------

  defp get(token, path, opts, params \\ []), do: request(token, :get, path, opts, params: params)
  defp post(token, path, body, opts), do: request(token, :post, path, opts, json: body)
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

  defp answer({:ok, %Req.Response{status: status} = response}, method, path) do
    Logger.warning("provision: Hetzner answered #{method} #{path} with #{status}")
    {:error, refusal(status, response)}
  end

  defp answer({:error, exception}, method, path) do
    message = bounded(Exception.message(exception))
    Logger.warning("provision: Hetzner #{method} #{path} did not answer: #{message}")
    {:error, {:unreachable, message}}
  end

  # Hetzner's error codes the provisioner answers by name; any other refusal
  # keeps Hetzner's own code and message.
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

  # A refusal Hetzner answered (a 4xx) means nothing was done; no answer, or
  # a 5xx, leaves it unknown. So does a name Hetzner already holds: the shared
  # pool sends a request again once when its connection closed under it
  # (`Net.HttpClient`), so the first may have been carried out.
  defp definitive?({:unreachable, _message}), do: false
  defp definitive?({:refused, status, _code, _message}) when status >= 500, do: false
  defp definitive?({:refused, 409, "uniqueness_error", _message}), do: false
  defp definitive?(_reason), do: true

  defp forget_if_refused(home, kind, reason) do
    if definitive?(reason) do
      with {:ok, _ledger} <- update(home, &{:ok, Ledger.remove(&1, kind)}), do: {:error, reason}
    else
      {:error, reason}
    end
  end

  defp bounded(text) when is_binary(text) do
    text
    |> String.replace(~r/[\x{0000}-\x{001F}\x{007F}]/u, " ")
    |> String.slice(0, @max_vendor_bytes)
    |> String.trim()
  end

  # -- the ledger -----------------------------------------------------------------

  defp read(home) do
    case Ledger.read(home, @host) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, {:ledger, reason}}
    end
  end

  defp update(home, fun) do
    case Ledger.update(home, @host, fun) do
      {:ok, ledger} -> {:ok, ledger}
      {:error, reason} -> {:error, {:ledger, reason}}
    end
  end

  defp token(%{token: token}) when is_binary(token), do: {:ok, token}
  defp token(_ledger), do: {:error, :no_token}

  defp report(opts, phase), do: Keyword.get(opts, :report, fn _phase -> :ok end).(phase)

  defp now(opts), do: DateTime.truncate(Keyword.get(opts, :now, &DateTime.utc_now/0).(), :second)

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      _invalid -> nil
    end
  end

  defp time(_text), do: nil
end
