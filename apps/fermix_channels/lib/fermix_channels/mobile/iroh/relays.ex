defmodule FermixChannels.Mobile.Iroh.Relays do
  @moduledoc """
  Fermix's iroh relays: every relay list a release has shipped, from
  `fermix_core/priv/mobile/relays.json`, built in at compile time (M62 §3.1).

  A phone is always given the current list. The daemon's own iroh endpoint uses
  only the relays every paired phone has acknowledged (`acknowledged/2`), so a
  phone that was offline through an upgrade that added a relay can still reach
  the daemon at a relay it knows.

  The build refuses a source with a duplicate revision, a revision that drops a
  relay of the first one (relay names are repointed, never removed), a revision
  that names a relay twice, a relay that is not `https://<lowercase name>/`
  (the pairing link's compact form keeps only the name), or a list longer than
  the helper takes.
  """

  defmodule Source do
    @moduledoc false
    # Parses and checks `relays.json` while `Relays` compiles; `Relays` is its
    # only caller.

    alias FermixChannels.Mobile.Iroh.Relays

    # The helper's `start` and `set_relays` take one to eight relays.
    @max_relays 8

    @spec canonical_json([Relays.relay()]) :: String.t()
    def canonical_json(relays) when is_list(relays) do
      entries =
        Enum.map(relays, fn %{url: url, quic_port: port} ->
          ~s({"quic_port":#{port},"url":#{Jason.encode!(url)}})
        end)

      "[" <> Enum.join(entries, ",") <> "]"
    end

    @spec parse!(map()) :: [Relays.revision()]
    def parse!(%{"revisions" => [_ | _] = entries}) do
      revisions = Enum.map(entries, &parse_revision!/1)
      ids = Enum.map(revisions, & &1.id)

      if length(Enum.uniq(ids)) != length(ids),
        do: raise(ArgumentError, "relays.json: two revisions have the same relays")

      launch_urls = revisions |> hd() |> urls()

      for %{id: id} = revision <- revisions, not MapSet.subset?(launch_urls, urls(revision)) do
        raise ArgumentError, "relays.json: revision #{id} drops a relay of the launch set"
      end

      revisions
    end

    def parse!(_source), do: raise(ArgumentError, "relays.json: no revisions")

    @spec urls(Relays.revision()) :: MapSet.t(String.t())
    def urls(%{relays: relays}), do: MapSet.new(relays, & &1.url)

    defp parse_revision!(%{"iroh" => iroh, "relays" => [_ | _] = entries})
         when is_binary(iroh) and length(entries) <= @max_relays do
      unless Regex.match?(~r/\A\d+\.\d+\.\d+\z/, iroh),
        do: raise(ArgumentError, "relays.json: iroh version #{inspect(iroh)} is not x.y.z")

      relays = Enum.map(entries, &parse_relay!/1)

      if length(Enum.uniq_by(relays, & &1.url)) != length(relays),
        do: raise(ArgumentError, "relays.json: a revision names a relay twice")

      digest = :crypto.hash(:sha256, canonical_json(relays))
      id = digest |> Base.encode16(case: :lower) |> binary_part(0, 16)
      %{id: id, iroh: iroh, relays: relays}
    end

    defp parse_revision!(entry),
      do: raise(ArgumentError, "relays.json: invalid revision #{inspect(entry)}")

    # The pairing link carries a relay as `host:quic_port` (M62 §4.2), which
    # keeps only a lowercase name and implies `https`, 443 and `/`: a URL with
    # anything else would not survive it.
    defp parse_relay!(%{"url" => url, "quic_port" => port} = entry)
         when is_binary(url) and is_integer(port) and port in 1..65_535 do
      host = URI.parse(url).host || ""

      if url == "https://#{host}/" and Regex.match?(~r/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/, host),
        do: %{url: url, quic_port: port},
        else: raise(ArgumentError, "relays.json: relay #{inspect(entry)} is not https://host/")
    end

    defp parse_relay!(entry),
      do: raise(ArgumentError, "relays.json: invalid relay #{inspect(entry)}")
  end

  alias FermixChannels.Mobile.Iroh.Relays.Source

  @source Path.expand("../../../../../fermix_core/priv/mobile/relays.json", __DIR__)
  @external_resource @source

  @typedoc "One relay: its `https` URL and its QUIC address-discovery port."
  @type relay :: %{url: String.t(), quic_port: 1..65_535}

  @typedoc """
  One shipped relay list: its id (the first 16 hex digits of the SHA-256 of its
  relays as canonical JSON), the iroh version its relays run, and its relays.
  """
  @type revision :: %{id: String.t(), iroh: String.t(), relays: [relay()]}

  @revisions @source |> File.read!() |> Jason.decode!() |> Source.parse!()

  @doc "Every shipped revision, oldest first."
  @spec revisions() :: [revision(), ...]
  def revisions, do: @revisions

  @doc "The relay list a phone is given now."
  @spec current() :: revision()
  def current, do: List.last(@revisions)

  @doc "The first revision's relays, which every later revision contains."
  @spec launch_set() :: [relay()]
  def launch_set, do: hd(@revisions).relays

  @doc """
  The relays the daemon's endpoint may use: those in the revision every one of
  `acknowledgments` names. An acknowledgment that is `nil` (a phone that never
  named one) or a revision this build does not know counts as the launch set,
  and so does an empty list (no paired phone). Order follows the current list.
  """
  @spec acknowledged([String.t() | nil], [revision(), ...]) :: [relay()]
  def acknowledged(acknowledgments, revisions \\ @revisions) when is_list(acknowledgments) do
    known = Map.new(revisions, &{&1.id, Source.urls(&1)})
    launch = Source.urls(hd(revisions))

    # Every revision contains the launch set, so neither the intersection nor
    # the filter below can come out empty.
    allowed = intersect(acknowledgments, known, launch)
    Enum.filter(List.last(revisions).relays, &MapSet.member?(allowed, &1.url))
  end

  defp intersect([], _known, launch), do: launch

  defp intersect(acknowledgments, known, launch) do
    acknowledgments
    |> Enum.map(&Map.get(known, &1, launch))
    |> Enum.reduce(&MapSet.intersection/2)
  end

  @doc "A relay list as the wire carries it."
  @spec to_wire([relay()]) :: [%{String.t() => String.t() | pos_integer()}]
  def to_wire(relays) when is_list(relays),
    do: Enum.map(relays, &%{"url" => &1.url, "quic_port" => &1.quic_port})
end
