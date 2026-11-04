defmodule FermixCore.Home.Provision.Offering do
  @moduledoc """
  The L2 rule (M75 lean v1 L2), the same for every provider: what Fermix
  offers from a provider's catalog (`Provision.catalog/2`, read live) and
  what it recommends.

  Offered: every type that is x86, has at least 4 GB and is still sold, in
  each of the provider's locations (`display/0`'s, in its order) where it is
  in stock and priced, at its gross monthly price as the account is billed
  plus the place's IPv4 address, cheapest first (among equals, in the
  provider's order of places). Recommended: the cheapest such type, in the
  first place where it is in stock. "More room": the cheapest type with more
  memory, where the recommendation is, or else the first place it is in
  stock. Prices are integers in ten-thousandths of the currency's unit
  until they are written as decimal strings with two places.

  Pure.
  """

  alias FermixCore.Home.Provision

  @min_memory_gb 4

  @doc """
  The offer for `provider` from its `catalog`: `currency`, `locations`
  (`{id, city, country}`), `offers`, `recommended` and `more_room` (each
  `{type, location}` or nil), as `home.provision.options` answers them.
  """
  @spec offering(module(), Provision.catalog()) :: map()
  def offering(provider, %{types: types, ipv4_monthly: ipv4} = catalog) do
    places = Provision.location_ids(provider)

    offers =
      types
      |> Enum.filter(&eligible?/1)
      |> Enum.flat_map(&offers(&1, ipv4, places))
      |> Enum.sort_by(&{units(&1["total_monthly"]), rank(places, &1["location"])})

    recommended = recommend(offers, places)

    %{
      "currency" => catalog.currency,
      "locations" => location_views(catalog.locations, places),
      "offers" => offers,
      "recommended" => recommended && pick(recommended),
      "more_room" => more_room(offers, recommended, places)
    }
  end

  @doc "Whether Fermix creates a server of `type`: x86, at least 4 GB, still sold."
  @spec eligible?(Provision.server_type()) :: boolean()
  def eligible?(%{x86: x86, sold: sold, memory_gb: memory}),
    do: x86 == true and sold == true and is_number(memory) and memory >= @min_memory_gb

  defp offers(type, ipv4, places) do
    for location <- places,
        location in type.stock,
        {:ok, monthly} <- [Map.fetch(type.monthly, location)] do
      address = Map.get(ipv4, location, 0)

      %{
        "type" => type.name,
        "description" => type.description,
        "cores" => type.cores,
        "memory_gb" => type.memory_gb,
        "disk_gb" => type.disk_gb,
        "dedicated" => type.dedicated,
        "location" => location,
        "monthly" => money(monthly),
        "ipv4_monthly" => money(address),
        "total_monthly" => money(monthly + address)
      }
    end
  end

  defp rank(places, location), do: Enum.find_index(places, &(&1 == location))

  # The cheapest type, in the first place where it is in stock.
  defp recommend([], _places), do: nil

  defp recommend([cheapest | _rest] = offers, places) do
    offers
    |> Enum.filter(&(&1["type"] == cheapest["type"]))
    |> Enum.min_by(&rank(places, &1["location"]))
  end

  defp more_room(_offers, nil, _places), do: nil

  defp more_room(offers, recommended, places) do
    case Enum.filter(offers, &(&1["memory_gb"] > recommended["memory_gb"])) do
      [] ->
        nil

      [next | _rest] = bigger ->
        same_type = Enum.filter(bigger, &(&1["type"] == next["type"]))
        here = Enum.find(same_type, &(&1["location"] == recommended["location"]))
        pick(here || Enum.min_by(same_type, &rank(places, &1["location"])))
    end
  end

  defp pick(offer), do: %{"type" => offer["type"], "location" => offer["location"]}

  defp location_views(locations, places) do
    for id <- places, %{} = location <- [Enum.find(locations, &(&1.id == id))] do
      %{"id" => id, "city" => location.city, "country" => location.country}
    end
  end

  # Ten-thousandths of a unit, written with two places, rounded half up.
  defp money(units) when is_integer(units) do
    cents = div(units + 50, 100)
    "#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp units(money) do
    [whole, cents] = String.split(money, ".")
    String.to_integer(whole) * 10_000 + String.to_integer(cents) * 100
  end
end
