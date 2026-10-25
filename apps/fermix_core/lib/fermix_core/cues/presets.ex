defmodule FermixCore.Cues.Presets do
  @moduledoc """
  Named source presets (M60 §6.10): a preset fills a source section's kind,
  endpoint and field paths, and every field the section writes itself wins.

  The table is one module attribute, so adding a preset is one entry. Values
  are in the normalized shape `Cues.Config.normalize/1` produces (atoms for
  enumerations, integers for seconds). A preset never carries a secret.

  A field a preset needs present is named in `Cues.Config.required_fields/3`,
  the one presence rule the config and the forms both read.
  """

  # rss: a feed poll every 15 minutes; the owner gives the URL.
  # github: a repository or organisation webhook (§6.10): GitHub's HMAC over
  # the raw body, its delivery id as identity and its event name as type; the
  # owner gives the signing secret (`Cues.Webhook` projects a body over 64 KiB).
  @presets %{
    "rss" => %{kind: :feed, interval: 900},
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

  A section with no preset comes back unchanged. An unknown preset, or a
  `:kind` that contradicts the preset's, is refused with a sentence for the
  owner.
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
        {:ok, Map.merge(preset, section)}
    end
  end
end
