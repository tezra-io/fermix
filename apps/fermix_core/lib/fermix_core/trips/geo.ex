defmodule FermixCore.Trips.Geo do
  @moduledoc """
  Distances on the globe for a trip, pure (M89 §04, §06): the straight line
  between two places in whole metres, the middle of a set of places, and how
  far a set reaches from a point.

  A point is a map with a `latitude` in -90..90 and a `longitude` in
  -180..180, in degrees; anything else in the map (a place record's name, its
  address) is ignored. The globe is a sphere of the mean Earth radius, which is
  within half a percent of the ellipsoid at every latitude: enough to tell a
  walk from a train, and to centre a search.
  """

  @earth_radius_m 6_371_000.0
  @degree :math.pi() / 180

  @typedoc "A place on the globe, in degrees."
  @type point :: %{
          required(:latitude) => number(),
          required(:longitude) => number(),
          optional(atom()) => term()
        }

  defguardp in_range(latitude, longitude)
            when is_number(latitude) and latitude >= -90 and latitude <= 90 and
                   is_number(longitude) and longitude >= -180 and longitude <= 180

  @doc "The great-circle distance from `a` to `b`, in metres, rounded."
  @spec distance_m(point(), point()) :: non_neg_integer()
  def distance_m(%{latitude: lat_a, longitude: lon_a}, %{latitude: lat_b, longitude: lon_b})
      when in_range(lat_a, lon_a) and in_range(lat_b, lon_b) do
    half_lat = (lat_b - lat_a) * @degree / 2
    half_lon = (lon_b - lon_a) * @degree / 2

    haversine =
      :math.pow(:math.sin(half_lat), 2) +
        :math.cos(lat_a * @degree) * :math.cos(lat_b * @degree) *
          :math.pow(:math.sin(half_lon), 2)

    # Rounding can carry two antipodal points a hair past one.
    round(2 * @earth_radius_m * :math.asin(:math.sqrt(min(haversine, 1.0))))
  end

  @doc """
  The middle of `points`, as a point holding only its `latitude` and
  `longitude`, or nil for none. The mean of the points as directions from the
  Earth's centre, so a set across the antimeridian has its middle there and
  not on the other side of the world.
  """
  @spec centroid([point()]) :: %{latitude: float(), longitude: float()} | nil
  def centroid([]), do: nil

  def centroid(points) when is_list(points) do
    {x, y, z} =
      points
      |> Enum.map(&direction/1)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y, z}, {sx, sy, sz} -> {sx + x, sy + y, sz + z} end)

    %{
      latitude: :math.atan2(z, :math.sqrt(x * x + y * y)) / @degree,
      longitude: :math.atan2(y, x) / @degree
    }
  end

  @doc "The largest distance from `point` to any of `points`, in metres; 0 for none."
  @spec spread_m(point(), [point()]) :: non_neg_integer()
  def spread_m(%{latitude: latitude, longitude: longitude} = point, points)
      when in_range(latitude, longitude) and is_list(points) do
    Enum.reduce(points, 0, fn other, widest -> max(widest, distance_m(point, other)) end)
  end

  defp direction(%{latitude: latitude, longitude: longitude})
       when in_range(latitude, longitude) do
    lat = latitude * @degree
    lon = longitude * @degree
    {:math.cos(lat) * :math.cos(lon), :math.cos(lat) * :math.sin(lon), :math.sin(lat)}
  end
end
