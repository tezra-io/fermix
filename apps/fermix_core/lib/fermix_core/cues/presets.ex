defmodule FermixCore.Cues.Presets do
  @moduledoc """
  Named source presets (M60 §6.10): a preset fills a source section's kind,
  endpoint and field paths, and every field the section writes itself wins.

  The table is one module attribute, so adding a preset is one entry. Values
  are in the normalized shape `Cues.Config.normalize/1` produces (atoms for
  enumerations, integers for seconds). A preset never carries a secret.

  A preset whose fields need a rule of their own (Bluesky's `dids`) adds one
  clause to `check_preset/2`, which runs on the filled section, so
  `Cues.Config` refuses such a source at the config boundary.
  """

  alias FermixCore.Cues.Jetstream

  # rss: a feed poll every 15 minutes; the owner gives the URL.
  # bluesky_jetstream: Bluesky's public Jetstream v2 (no account); the owner
  # gives the dids to follow, collections default to posts (`Cues.Jetstream`).
  # github: a repository or organisation webhook (§6.10): GitHub's HMAC over
  # the raw body, its delivery id as identity and its event name as type; the
  # owner gives the signing secret (`Cues.Webhook` projects a body over 64 KiB).
  @presets %{
    "rss" => %{kind: :feed, interval: 900},
    "bluesky_jetstream" => %{
      kind: :stream,
      url: Jetstream.default_base_url(),
      collections: Jetstream.default_collections()
    },
    "github" => %{
      kind: :webhook,
      verify: :hmac,
      header: "X-Hub-Signature-256",
      algorithm: "sha256",
      prefix: "sha256=",
      id_header: "X-GitHub-Delivery",
      type_header: "X-GitHub-Event"
    }
  }

  @doc "Every preset name, sorted."
  @spec names() :: [String.t()]
  def names, do: @presets |> Map.keys() |> Enum.sort()

  @doc """
  What preset `name` fills (its kind and default fields), for a surface that
  shows the defaults a section leaves to its preset. No rule is checked.
  """
  @spec defaults(String.t()) :: {:ok, map()} | :error
  def defaults(name) when is_binary(name), do: Map.fetch(@presets, name)

  @doc """
  Fills `section` (a map with atom keys, normalized values) from its `:preset`.

  A section with no preset comes back unchanged. An unknown preset, a `:kind`
  that contradicts the preset's, or a filled section the preset's own rule
  refuses, is refused with a sentence for the owner.
  """
  @spec fill(map()) :: {:ok, map()} | {:error, String.t()}
  def fill(section) when is_map(section) do
    case Map.fetch(section, :preset) do
      :error -> {:ok, section}
      {:ok, name} -> apply_preset(section, name)
    end
  end

  defp apply_preset(section, name) do
    case Map.fetch(@presets, name) do
      {:ok, preset} ->
        merge(section, name, preset)

      :error ->
        {:error, "unknown preset #{inspect(name)}; known presets: #{Enum.join(names(), ", ")}"}
    end
  end

  defp merge(section, name, %{kind: kind} = preset) do
    case Map.fetch(section, :kind) do
      {:ok, other} when other != kind ->
        {:error, "preset #{name} makes a #{kind} source; remove kind or set it to #{kind}"}

      _same_or_absent ->
        filled = Map.merge(preset, section)

        with :ok <- check_preset(name, filled), do: {:ok, filled}
    end
  end

  # One clause per preset with a rule of its own; every other preset has none.
  defp check_preset("bluesky_jetstream", filled),
    do:
      Jetstream.check_subscription(Map.get(filled, :dids, []), Map.get(filled, :collections, []))

  defp check_preset(_name, _filled), do: :ok
end
