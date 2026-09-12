defmodule FermixCore.Management.Settings.Row do
  @moduledoc """
  One descriptor row, and the only place its wire shape is written.

  Every field is always present, `null` where it does not apply, because the
  client decodes a fixed record rather than probing for keys (M34 native setup
  §7.3). A row is data: the label, the footer, the options, the bounds and the
  restart flag are the daemon's, and no front-end composes its own.

  `restart` is derived, never hand-listed: a row is flagged exactly when its own
  configuration section is one `Setup.RestartState` compares against the boot
  baseline. Declaring it per row would let a row claim "no restart needed" for a
  change that makes the very next `overview.get` ask for one.

  `suggestions` says whether a choice row's `options` are the WHOLE value space
  or only what a client may offer inline. It is the field `settings.apply`
  validates against: without it every choice row accepted any string, and an
  off-list word reached the writer's `String.to_existing_atom/1` and came back
  to the operator as an Elixir exception message under the control they just
  used.
  """

  alias FermixCore.Setup.RestartState

  @kinds ~w(toggle choice text number secret list)a
  @formats ~w(integer percent currency_cents minutes hours)a

  @type kind :: :toggle | :choice | :text | :number | :secret | :list
  @type t :: %{optional(String.t()) => term()}

  @doc "Every row kind this contract publishes."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Every number format this contract publishes."
  @spec formats() :: [atom()]
  def formats, do: @formats

  @doc """
  Builds one row.

  `:restart` is mandatory and is expected to come from `restart?/1`, so a row
  cannot be published with a restart claim nobody derived.
  """
  @spec new(String.t(), kind(), String.t(), keyword()) :: t()
  def new(key, kind, label, opts)
      when is_binary(key) and kind in @kinds and is_binary(label) and is_list(opts) do
    restart = validate_restart!(key, Keyword.fetch!(opts, :restart))
    format = validate_format!(key, Keyword.get(opts, :format))

    %{
      "key" => key,
      "kind" => Atom.to_string(kind),
      "label" => label,
      "footer" => Keyword.get(opts, :footer),
      "value" => value(Keyword.get(opts, :value)),
      "present" => Keyword.get(opts, :present),
      "options" => Keyword.get(opts, :options, []),
      "min" => Keyword.get(opts, :min),
      "max" => Keyword.get(opts, :max),
      "step" => Keyword.get(opts, :step),
      "restart" => restart,
      "read_only" => Keyword.get(opts, :read_only, false),
      "suggestions" => suggestions?(kind, opts),
      "unit" => Keyword.get(opts, :unit),
      "format" => format && Atom.to_string(format)
    }
  end

  @doc "One option of a choice row. `hint` and `disabled` are the daemon's."
  @spec option(String.t(), String.t(), keyword()) :: map()
  def option(value, label, opts \\ []) when is_binary(value) and is_binary(label) do
    %{
      "value" => value,
      "label" => label,
      "hint" => Keyword.get(opts, :hint),
      "disabled" => Keyword.get(opts, :disabled, false)
    }
  end

  @doc """
  Whether a change to a row in `section` needs a restart.

  Read from `RestartState`'s own boot-bound list, which is the same list that
  decides what `restart.required` reports after the write lands.
  """
  @spec restart?(atom()) :: boolean()
  def restart?(section) when is_atom(section) do
    List.keymember?(RestartState.boot_bound_sections(), section, 0)
  end

  @doc "A configuration value as the wire carries it."
  @spec value(term()) :: term()
  def value(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  def value(value) when is_list(value), do: Enum.map(value, &to_string/1)
  def value(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  def value(nil), do: nil

  # Meaningful on a choice row only, and false everywhere else: a row whose
  # options are not the value space has to say so, and a row with no options at
  # all has no space to be a subset of.
  defp suggestions?(:choice, opts), do: Keyword.get(opts, :suggestions, false) == true
  defp suggestions?(_kind, _opts), do: false

  defp validate_restart!(_key, restart) when is_boolean(restart), do: restart

  defp validate_restart!(key, restart) do
    raise ArgumentError, "row #{key} declared a non-boolean restart: #{inspect(restart)}"
  end

  defp validate_format!(_key, nil), do: nil
  defp validate_format!(_key, format) when format in @formats, do: format

  defp validate_format!(key, format) do
    raise ArgumentError, "row #{key} declared an unpublished number format: #{inspect(format)}"
  end
end
