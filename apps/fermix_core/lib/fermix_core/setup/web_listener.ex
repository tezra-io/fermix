defmodule FermixCore.Setup.WebListener do
  @moduledoc """
  The one resolver for the HTTP listener's port (M38 §4.7).

  Four surfaces need this answer and must never disagree about it: the daemon's
  own endpoint at boot, the browser setup launcher, `hello`'s published
  `setup.origin`, and `fermix service status`. So the policy lives here and
  nothing re-derives it.

  **Two distribution configurations, not a fallback chain.**

    * A **packaged** engine takes the port from `[fermix_web] port` in its home's
      settings, and **refuses** a `PORT` environment variable outright. One unit
      file serves every account on the machine and carries no per-account
      values, so a shell variable that quietly moved the listener would leave a
      daemon answering on a port nothing else can predict. The refusal names the
      persisted setting, which is the thing that works while the daemon is down.
    * **Standalone and source** keep `PORT`, exactly as they always have, and
      fall to the persisted setting and then the default when it is unset.

  Which branch runs is decided by the compiled distribution identity — a value
  present on every engine — not by which input happens to be absent.

  **The persisted setting is bounded at 1024 through 65535**, because a home
  setting is applied by an unprivileged user daemon and a privileged port would
  fail at bind with nothing to point at. `PORT` keeps its historical 1 through
  65535, because narrowing it would refuse an install that works today.
  """

  alias FermixCore.Setup.ConfigStore

  @default_port 4030
  @min_configured_port 1024
  @max_port 65_535

  @type source :: :environment | :config | :default
  @type resolution :: %{port: 1..65_535, source: source()}
  @type failure :: {:invalid_port, :environment, term()} | {:port_not_used, String.t()}

  @doc "The port used when nothing is configured."
  @spec default_port() :: pos_integer()
  def default_port, do: @default_port

  @doc "The inclusive bounds a persisted `[fermix_web] port` must fall inside."
  @spec configured_bounds() :: Range.t()
  def configured_bounds, do: @min_configured_port..@max_port

  @doc """
  Whether `value` is a port this settings file may record.

  The one predicate behind the parser's refusal and the CLI's `--port`
  validation, so a value one accepts the other cannot reject.
  """
  @spec valid_configured_port?(term()) :: boolean()
  def valid_configured_port?(value) when is_integer(value) do
    value >= @min_configured_port and value <= @max_port
  end

  def valid_configured_port?(_value), do: false

  @doc "The sentence a refused `[fermix_web] port` value carries."
  @spec invalid_port_sentence(term()) :: String.t()
  def invalid_port_sentence(value) do
    "the web listener port must be a whole number from #{@min_configured_port} through " <>
      "#{@max_port}, and #{inspect(value)} is not"
  end

  @doc """
  The sentence a packaged engine answers a `PORT` override with.

  It carries no command prefix of its own, because three surfaces print it —
  the boot refusal, `fermix setup` and the browser launcher — and each already
  names itself. A prefix baked in here would be printed twice.
  """
  @spec port_not_used_sentence() :: String.t()
  def port_not_used_sentence do
    "PORT is not used by the packaged engine; set the port with " <>
      "fermix service install --port N"
  end

  @doc """
  Resolves the listener port for one distribution and one environment.

  `env` is the environment as a map (`System.get_env/0`'s shape). `opts` may
  carry `:configured`, the persisted `[fermix_web] port` or `nil`; when it is
  absent the value is read from the live application environment, which the
  boot hydration has already filled in from the settings file.
  """
  @spec port(String.t(), map(), keyword()) :: {:ok, resolution()} | {:error, failure()}
  def port(distribution, env, opts \\ [])
      when is_binary(distribution) and is_map(env) and is_list(opts) do
    configured = Keyword.get_lazy(opts, :configured, &configured_port/0)

    case {distribution, environment_value(env)} do
      {"linux_package", :absent} -> {:ok, resolved(configured)}
      {"linux_package", _present} -> {:error, {:port_not_used, port_not_used_sentence()}}
      {_other, :absent} -> {:ok, resolved(configured)}
      {_other, {:present, value}} -> from_environment(value)
      {_other, {:unusable, value}} -> {:error, {:invalid_port, :environment, value}}
    end
  end

  @doc """
  The persisted port in the live application environment, or `nil`.

  Written by `ConfigStore.apply_snapshot/2` from the settings file, so it is the
  same value every other surface sees.
  """
  @spec configured_port() :: pos_integer() | nil
  def configured_port do
    :fermix_web |> Application.get_env(:listener, []) |> Keyword.get(:port)
  end

  @doc """
  The persisted port recorded in one home's settings file, or `nil`.

  `fermix service status` runs with no daemon and, on a packaged install, with a
  home chosen by the binding rather than by this process's environment — so the
  home is named rather than assumed.
  """
  @spec configured_port(Path.t()) :: {:ok, pos_integer() | nil} | {:error, term()}
  defdelegate configured_port(home), to: ConfigStore, as: :web_port

  defp resolved(nil), do: %{port: @default_port, source: :default}
  defp resolved(port) when is_integer(port), do: %{port: port, source: :config}

  defp from_environment(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port > 0 and port <= @max_port ->
        {:ok, %{port: port, source: :environment}}

      _invalid ->
        {:error, {:invalid_port, :environment, value}}
    end
  end

  # An unset or blank `PORT` is "not supplied", which is what it has always
  # meant. A value of some other shape is a mistake to name, not a reason to
  # quietly take the default.
  defp environment_value(env) do
    case Map.get(env, "PORT") do
      value when is_binary(value) and value != "" -> {:present, value}
      value when is_binary(value) or is_nil(value) -> :absent
      unusable -> {:unusable, unusable}
    end
  end
end
