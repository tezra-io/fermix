defmodule FermixCore.Cues.SourceName do
  @moduledoc """
  The name Fermix gives a new source the owner left unnamed (M60 simpler
  setup §7, D2): what the source reads, as the owner would say it.

    * A feed or a stream takes its address's site: the label before the top
      level (`news.ycombinator.com` is `ycombinator`), and under a country's
      two-letter top level before its registry level too (`bbc.co.uk` is
      `bbc`, `abc.com.au` is `abc`). An address with no such label
      (an IP address, a host with no Latin letters, or no address at all) is
      named for its kind, `feed` or `stream`.
    * X accounts takes `x-` and its first handle (`x-nasa`), or `x-accounts`
      with none.
    * GitHub is `github`, a local push source `scripts`, any other webhook
      `webhook`.

  The name then keeps lowercase letters and digits, its accents dropped, with
  one hyphen for each run of anything else, within
  `Cues.Config.max_name_length/0`. A name already taken gets `-2`, `-3`, and
  so on. As many names are tried as a settings file holds sources
  (`Cues.Config.max_sources/0`), so one is free whenever there is room for
  another source; past that the name is refused.

  Pure: the caller passes the section the save writes and the names taken.
  """

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.Presets

  @all_taken "Every name Fermix tried for this source is taken. Give it a name."
  @two_letters ~r/\A[a-z]{2}\z/
  # Second levels a country's registry keeps for itself, beside two-letter ones.
  @registry_levels ~w(com net org gov edu)

  @doc """
  A free name for the source `section` makes (the persisted shape: its
  `preset` or `kind`, and its `url` or `handles`), against `taken`. Raises
  when the section names neither a kind nor a preset this daemon knows.
  """
  @spec make(keyword(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def make(section, taken) when is_list(section) and is_list(taken) do
    kind = kind!(section)
    base = section |> said(kind) |> clean() |> or_kind(kind)
    taken = MapSet.new(taken)

    case Enum.find(1..CuesConfig.max_sources(), &free?(candidate(base, &1), taken)) do
      nil -> {:error, @all_taken}
      try -> {:ok, candidate(base, try)}
    end
  end

  defp kind!(section) do
    case {Keyword.get(section, :preset), Keyword.get(section, :kind)} do
      {nil, kind} when is_atom(kind) and not is_nil(kind) -> Atom.to_string(kind)
      {nil, kind} when is_binary(kind) -> kind
      {preset, _kind} when is_binary(preset) -> preset_kind!(preset)
      _neither -> raise ArgumentError, "a source section names its kind or its preset"
    end
  end

  defp preset_kind!(preset) do
    case Presets.defaults(preset) do
      {:ok, %{kind: kind}} -> Atom.to_string(kind)
      :error -> raise ArgumentError, "unknown preset #{inspect(preset)}"
    end
  end

  # What the source reads, before it is made a name.
  defp said(section, kind) do
    case {Keyword.get(section, :preset), kind} do
      {"x_accounts", _kind} -> x_name(Keyword.get(section, :handles))
      {"github", _kind} -> "github"
      {_preset, "local_push"} -> "scripts"
      {_preset, "webhook"} -> "webhook"
      {_preset, kind} when kind in ["feed", "stream"] -> site(Keyword.get(section, :url))
    end
  end

  defp x_name([first | _rest]) when is_binary(first),
    do: "x-" <> (first |> String.trim() |> String.trim_leading("@"))

  defp x_name(_none), do: "x-accounts"

  defp site(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: host} when is_binary(host) and host != "" -> host |> String.downcase() |> label()
      _no_host -> ""
    end
  end

  defp site(_no_url), do: ""

  defp label(host) do
    if ip_address?(host),
      do: "",
      else: host |> String.split(".", trim: true) |> site_label()
  end

  defp ip_address?(host), do: match?({:ok, _ip}, :inet.parse_address(String.to_charlist(host)))

  defp site_label([]), do: ""
  defp site_label([only]), do: only

  defp site_label(labels) do
    [top | below] = Enum.reverse(labels)
    below |> without_registry_level(top) |> hd()
  end

  # Under a country's two-letter top level, its registry's second level (`co`
  # in `bbc.co.uk`, `com` in `abc.com.au`) is skipped when a label stands
  # before it. `below` runs from the top level down.
  defp without_registry_level([second, _site | _rest] = below, top) do
    if Regex.match?(@two_letters, top) and registry_level?(second),
      do: tl(below),
      else: below
  end

  defp without_registry_level(below, _top), do: below

  defp registry_level?(label), do: Regex.match?(@two_letters, label) or label in @registry_levels

  defp clean(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> within(CuesConfig.max_name_length())
  end

  defp or_kind("", kind), do: kind
  defp or_kind(name, _kind), do: name

  defp candidate(base, 1), do: base

  defp candidate(base, try) do
    suffix = "-#{try}"
    within(base, CuesConfig.max_name_length() - String.length(suffix)) <> suffix
  end

  # At most `max` characters, with no hyphen left at either end.
  defp within(name, max),
    do: name |> String.trim("-") |> String.slice(0, max) |> String.trim_trailing("-")

  defp free?(name, taken), do: not MapSet.member?(taken, name)
end
