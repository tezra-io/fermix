defmodule FermixCore.Tools.PlaceSearch.Config do
  @moduledoc """
  `[fermix_core.tools.place_search]`: the one choice of place search backend
  (M72 §14.1).

      [fermix_core.tools.place_search]
      backend = "apple_maps"   # or "brave"; absent, the platform decides

  `backend` absent leaves the choice to `PlaceSearch.Backend.resolve/2`: the
  build's default, Apple Maps in the Fermix Mac app and Brave in the Homebrew
  and Linux builds. The file spells the backend as a string;
  `normalize/1` reads it into an atom and refuses any other word or key, so a
  typo stops the load naming the key rather than quietly running another
  backend. `to_keyword/1` is the inverse the persist path writes, so a save
  reads back as the same choice (AGENTS.md, Config round-trips).
  """

  @backends %{"apple_maps" => :apple_maps, "brave" => :brave}
  @keys ~w(backend)

  @type backend :: :apple_maps | :brave
  @type t :: %{backend: backend() | nil}

  @doc "Every backend a configuration may name, in the order a choice lists them."
  @spec backends() :: [backend()]
  def backends, do: [:apple_maps, :brave]

  @doc """
  The section in force, read from application environment.

  The one config read; everything else here is pure.
  """
  @spec current() :: t()
  def current do
    tools = Application.get_env(:fermix_core, :tools, [])

    if is_list(tools),
      do: normalize(Keyword.get(tools, :place_search, [])),
      else: normalize(nil)
  end

  @doc """
  Reads one section, from the file (string keys and values) or from
  application environment (atom keys, string or atom values).

  Raises `ArgumentError` naming the key on an unknown key or backend.
  """
  @spec normalize(keyword() | map() | nil) :: t()
  def normalize(nil), do: %{backend: nil}

  def normalize(config) when is_list(config) or is_map(config) do
    validate_keys!(config)
    %{backend: backend(lookup(config))}
  end

  @doc "The persisted shape of a normalized section: TOML has no atom type."
  @spec to_keyword(t()) :: keyword()
  def to_keyword(%{backend: nil}), do: []

  def to_keyword(%{backend: backend}) when backend in [:apple_maps, :brave],
    do: [backend: Atom.to_string(backend)]

  defp lookup(config) when is_map(config),
    do: Map.get(config, "backend", Map.get(config, :backend))

  defp lookup(config) when is_list(config), do: Keyword.get(config, :backend)

  defp backend(nil), do: nil
  defp backend(value) when value in [:apple_maps, :brave], do: value

  defp backend(value) when is_binary(value) do
    case Map.fetch(@backends, value |> String.trim() |> String.downcase()) do
      {:ok, backend} -> backend
      :error -> unknown_backend!(value)
    end
  end

  defp backend(value), do: unknown_backend!(value)

  defp unknown_backend!(value) do
    raise ArgumentError, """
    config.toml [fermix_core.tools.place_search] has an unknown backend: #{inspect(value)}.

    Allowed backends: #{Enum.join(Map.keys(@backends), ", ")}, or none for this platform's default.
    Remove or fix `backend`; the daemon will not boot until this is fixed.
    """
  end

  defp validate_keys!(config) do
    unknown =
      config
      |> section_keys()
      |> Enum.reject(&(&1 in @keys))
      |> Enum.sort()

    if unknown != [] do
      raise ArgumentError, """
      config.toml [fermix_core.tools.place_search] has unknown key(s): #{Enum.join(unknown, ", ")}.

      Allowed keys: #{Enum.join(@keys, ", ")}.
      Remove or fix the key(s); the daemon will not boot until this is fixed.
      """
    end
  end

  defp section_keys(config) when is_map(config),
    do: config |> Map.keys() |> Enum.map(&to_string/1)

  defp section_keys(config) when is_list(config),
    do: Enum.map(config, fn {key, _value} -> to_string(key) end)
end
