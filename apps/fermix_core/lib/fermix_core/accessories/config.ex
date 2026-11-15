defmodule FermixCore.Accessories.Config do
  @moduledoc """
  `[fermix_channels.accessories]` in this computer's `machine.toml` (M91, M97
  §4): whether this engine runs the accessory link, the wired connection a
  desk companion such as StackChan attaches over.

  Phase A has one key, `enabled`, a boolean, off when the section says
  nothing. `FermixChannels.Accessories` starts its subtree only when it is on,
  and only on a local Mac primary; the section stays on this computer when
  the home moves (`Setup.MachineFile`). There is no environment-variable
  overlay: the file owns the setting.

  Read through `FermixCore.Setup.ConfigStore` like every other section (here
  in core because the store must use it and core never depends on channels):
  `normalize/1` turns any shape the section arrives in into a struct at the
  parse boundary and refuses a non-boolean `enabled` by name, and
  `to_keyword/1` is the inverse the persist path writes (the "Config
  round-trips" rule). The off default is omitted from that keyword, so a home
  that never turned the link on keeps a `config.toml` with no section, and
  application environment holds `[]` or `[enabled: true]`.
  """

  @section "fermix_channels.accessories"

  @type t :: %__MODULE__{enabled?: boolean()}

  defstruct enabled?: false

  @doc "The section application environment holds, normalized."
  @spec current() :: t()
  def current, do: :fermix_channels |> Application.get_env(:accessories, []) |> normalize()

  @doc "Whether the accessory link is switched on in application environment."
  @spec enabled?() :: boolean()
  def enabled?, do: current().enabled?

  @doc """
  The section as a struct. Accepts `nil` (no section), the parsed file (a map
  with string keys), the app-env shape (a keyword or map with atom keys),
  `to_keyword/1`'s output and its own. Raises `ArgumentError` naming the key
  when `enabled` is anything but `true` or `false`.

  A key it does not know is ignored, deliberately: a later phase adds keys to
  this section (Phase B's network keys), and refusing them would stop an
  older daemon from booting a home a newer one wrote, which is exactly the
  daemon a rollback runs. The next save from such a daemon drops the key.
  """
  @spec normalize(t() | keyword() | map() | nil) :: t()
  def normalize(nil), do: %__MODULE__{}
  def normalize(%__MODULE__{} = config), do: config

  def normalize(config) when is_list(config) or (is_map(config) and not is_struct(config)) do
    case config |> Enum.map(&entry!/1) |> List.keyfind("enabled", 0) do
      nil -> %__MODULE__{}
      {"enabled", value} -> %__MODULE__{enabled?: enabled!(value)}
    end
  end

  def normalize(other), do: not_a_table!(other)

  @doc """
  The inverse of `normalize/1`, in the spelling `config.toml` and application
  environment hold: `[]` when off, so the default is never written, and
  `[enabled: true]` when on.
  """
  @spec to_keyword(t()) :: keyword()
  def to_keyword(%__MODULE__{enabled?: false}), do: []
  def to_keyword(%__MODULE__{enabled?: true}), do: [enabled: true]

  defp entry!({key, value}) when is_binary(key) or is_atom(key), do: {to_string(key), value}
  defp entry!(other), do: not_a_table!(other)

  defp not_a_table!(value) do
    raise ArgumentError,
          "#{@section} is not a table: #{inspect(value)}. Fix it in machine.toml; " <>
            "the daemon will not boot until this is fixed."
  end

  defp enabled!(value) when is_boolean(value), do: value

  defp enabled!(value) do
    raise ArgumentError,
          "#{@section}.enabled must be true or false, not #{inspect(value)}. Fix it in " <>
            "machine.toml; the daemon will not boot until this is fixed."
  end
end
