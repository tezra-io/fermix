defmodule FermixCore.Management.Settings.Source do
  @moduledoc """
  Reads values out of the one snapshot every settings section projects.

  The snapshot is `ConfigStore.current_snapshot/0`, live application
  environment in its persistable shape. It is deliberately the same value
  `settings.apply` reduces, so a row shows what the next write starts from
  rather than a second reading of the same configuration.
  """

  alias FermixCore.Setup.SecretPaths
  alias FermixCore.Setup.SecretStore

  @type snapshot :: map()

  @doc "One `[fermix_core.<section>]` block."
  @spec core(snapshot(), atom()) :: keyword()
  def core(snapshot, section) when is_map(snapshot) and is_atom(section) do
    snapshot |> Map.get(:fermix_core, []) |> Keyword.get(section, []) |> list()
  end

  @doc "One `[fermix_core.tools.<tool>]` block."
  @spec tool(snapshot(), atom()) :: keyword()
  def tool(snapshot, tool) when is_map(snapshot) and is_atom(tool) do
    snapshot |> core(:tools) |> Keyword.get(tool, []) |> list()
  end

  @doc "One provider block."
  @spec provider(snapshot(), atom()) :: keyword()
  def provider(snapshot, id) when is_map(snapshot) and is_atom(id) do
    snapshot |> core(:providers) |> Keyword.get(id, []) |> list()
  end

  @doc "One channel block."
  @spec channel(snapshot(), atom()) :: keyword()
  def channel(snapshot, name) when is_map(snapshot) and is_atom(name) do
    snapshot |> Map.get(:fermix_channels, []) |> Keyword.get(name, []) |> list()
  end

  @doc """
  Whether a secret sits at its own `SecretPaths` path.

  "Present" is a sentinel or a plaintext value at the path, never "the keychain
  holds an item": a key stored without its sentinel is never read back, so
  reporting it present would describe a credential the runtime cannot use.
  """
  @spec secret_present?(snapshot(), atom()) :: boolean()
  def secret_present?(snapshot, key) when is_map(snapshot) and is_atom(key) do
    value = SecretStore.get_snapshot_value(snapshot, SecretPaths.fetch!(key).path)
    is_binary(value) and value != ""
  end

  @doc "A keyword value, or an empty list where the block is absent or malformed."
  @spec list(term()) :: keyword()
  def list(value) when is_list(value), do: value
  def list(_value), do: []

  @doc "A string value with a default, for a row whose control is a text field."
  @spec string(keyword(), atom(), String.t()) :: String.t()
  def string(block, key, default \\ "") when is_list(block) and is_atom(key) do
    case Keyword.get(block, key) do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _absent -> default
    end
  end

  @doc "A boolean value with a default."
  @spec boolean(keyword(), atom(), boolean()) :: boolean()
  def boolean(block, key, default) when is_list(block) and is_atom(key) and is_boolean(default) do
    case Keyword.get(block, key) do
      value when is_boolean(value) -> value
      _absent -> default
    end
  end

  @doc "A number value with a default."
  @spec number(keyword(), atom(), number()) :: number()
  def number(block, key, default) when is_list(block) and is_atom(key) and is_number(default) do
    case Keyword.get(block, key) do
      value when is_number(value) -> value
      _absent -> default
    end
  end

  @doc "A list-of-strings value."
  @spec strings(keyword(), atom()) :: [String.t()]
  def strings(block, key) when is_list(block) and is_atom(key) do
    case Keyword.get(block, key) do
      values when is_list(values) -> Enum.map(values, &to_string/1)
      _absent -> []
    end
  end
end
