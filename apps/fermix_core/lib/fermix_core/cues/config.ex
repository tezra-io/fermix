defmodule FermixCore.Cues.Config do
  @moduledoc """
  `[fermix_core.cues]` config (M60 §6.2, §10.1, §15).

  Three scalar keys (`enabled`, `mandates_enabled`, `door_port`) and two tables
  of sections: `[fermix_core.cues.sources.<ref>]` and
  `[fermix_core.cues.mandates.<name>]`, a mandate's `pin_args` being its own
  sub-table (`[fermix_core.cues.mandates.<name>.pin_args]`), because the config
  parser reads one assignment per line.

  `normalize/1` validates types and shapes at the parse boundary and raises an
  `ArgumentError` naming the key; it keeps only the keys present, so a save
  writes the file back as the owner wrote it. Enumerations become atoms there,
  and `to_keyword/1` is the inverse the persist path uses (the "Config
  round-trips" rule). Durations stay the strings the owner wrote ("30m"); the
  accessors read them as seconds. Semantic mandate checks (the owner's inbox,
  tool kinds, validator ownership) belong to `Cues.Mandates`.

  A secret field (`token`, `key`, `secret`, and a webhook's `path_secret`,
  which `Cues.Webhook.ensure_path_secret/2` writes) holds only a sentinel,
  `@keyring` or `@file`, naming the store the value is in under
  `cue_source:<ref>:<field>`; `secret/2` resolves it on demand, so the value is
  never in application environment. A source that needs a secret (a webhook's
  `secret`, a local push's `token`, the `key` or `secret` a stream with no
  preset signs in with) and whose section has no sentinel for it loads with
  `missing_secret` naming the first such field: it waits for the secret rather
  than refusing the whole section (M60 app surface §3.8 item 3), and neither
  the door nor a worker serves it until it is stored.

  A stream is `wss://` only. It is the general WebSocket source, and the shape
  rules of its own fields are `Cues.JsonStream.check_config/1`'s.

  A feed with preset `x_accounts` names `handles` instead of a `url`: it
  builds its own address, and the handle rule is `Cues.XAccounts.handles/1`'s
  (stored without `@`, lowercased, once each). `handles` applies to no other
  source.
  """

  alias FermixCore.Cues.JsonStream
  alias FermixCore.Cues.Presets
  alias FermixCore.Cues.Webhook
  alias FermixCore.Cues.XAccounts
  alias FermixCore.Setup.SecretWriter

  @default_door_port 4032
  @door_ports 1024..65_535
  @min_interval_s 60
  @default_approve_within_s 1_800
  @max_approve_within_s 86_400
  @default_max_cue_age_s 900

  @name_pattern ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
  @pin_key_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]{0,63}\z/
  @duration_pattern ~r/\A([1-9][0-9]{0,6})([smh])\z/
  # A float the config parser reads back as the same float.
  @float_text_pattern ~r/\A-?\d+\.\d+\z/

  @config_keys [:enabled, :mandates_enabled, :door_port, :sources, :mandates]
  @kinds [:stream, :feed, :webhook, :local_push]
  @verify_methods [:shared_secret, :hmac, :standard_webhooks]
  @id_choices [:content_hash]
  # How a signed or shared-secret webhook tells one delivery from another.
  @identity_fields [:id_header, :id_path, :id]
  @modes [:approve, :auto]
  @secret_fields SecretWriter.cue_secret_fields()

  @path_fields [:items_path, :id_path, :revision_path, :type_path, :subject_path, :time_path]
  # How a stream with no preset signs in (`Cues.JsonStream`).
  @sign_in_fields [:key_header, :secret_header, :auth_message, :subscribe_message]
  @string_source_fields [:preset, :url, :id_header, :type_header, :header, :algorithm, :prefix] ++
                          @path_fields ++ @sign_in_fields
  @list_source_fields [:item_types, :error_types]

  @source_keys [:kind, :preset, :enabled, :url, :handles, :interval] ++
                 @path_fields ++
                 [:item_types, :error_types] ++
                 @sign_in_fields ++
                 [:id_header, :type_header, :id, :verify, :header, :algorithm, :prefix] ++
                 [:daily_budget | @secret_fields]

  @mandate_keys [
    :job,
    :enabled,
    :mode,
    :approve_within,
    :tools,
    :read_tools,
    :max_cue_age,
    :validator,
    :interpreter,
    :validator_env,
    :idempotency_arg,
    :unpinned,
    :pin_args
  ]

  # Which kinds a field means anything for; a field outside its kinds is
  # refused rather than silently ignored. Fields not listed apply to every kind.
  @field_kinds Map.merge(
                 Map.new(@path_fields, &{&1, [:stream, :feed, :webhook]}),
                 %{
                   url: [:stream, :feed],
                   handles: [:feed],
                   interval: [:feed],
                   item_types: [:stream],
                   error_types: [:stream],
                   key_header: [:stream],
                   secret_header: [:stream],
                   auth_message: [:stream],
                   subscribe_message: [:stream],
                   id_header: [:webhook],
                   type_header: [:webhook],
                   id: [:webhook],
                   verify: [:webhook],
                   header: [:webhook],
                   algorithm: [:webhook],
                   prefix: [:webhook],
                   key: [:stream, :feed, :webhook],
                   secret: [:stream, :feed, :webhook],
                   path_secret: [:webhook]
                 }
               )

  @required_by_kind %{
    stream: [:url],
    feed: [:url, :interval],
    webhook: [:verify],
    local_push: []
  }

  # The secret a kind cannot run without; a stream with no preset needs the
  # ones its sign-in names (`needed_secrets/1`). A source whose section has no
  # sentinel for one still loads, waiting for it (`missing_secret`): the source
  # is added first and its secret stored after (M60 app surface §3.5), and the
  # door and the workers leave it alone until then.
  @required_secret_by_kind %{webhook: :secret, local_push: :token}

  # The secret fields each kind declares, in the order a surface lists them. A
  # local-push token and a webhook's `path_secret` are Fermix's to make; `key`
  # and `secret` are what the owner types.
  @secret_fields_by_kind %{
    local_push: [:token],
    feed: [:key, :secret],
    stream: [:key, :secret],
    webhook: [:key, :secret, :path_secret]
  }

  # The most sources and mandates one settings file is given from a surface,
  # which keeps every list the management socket publishes inside its bound.
  @max_sources 64
  @max_mandates 64

  @type t :: keyword()
  @type kind :: :stream | :feed | :webhook | :local_push
  @type secret_field :: :token | :key | :secret | :path_secret

  @type source :: %{
          required(:ref) => String.t(),
          required(:kind) => kind(),
          required(:enabled?) => boolean(),
          required(:daily_budget) => non_neg_integer(),
          required(:secrets) => %{optional(secret_field()) => SecretWriter.store()},
          required(:missing_secret) => secret_field() | nil,
          optional(atom()) => term()
        }

  @type mandate :: %{
          name: String.t(),
          job: String.t(),
          enabled?: boolean(),
          mode: :approve | :auto,
          approve_within_s: pos_integer(),
          tools: [String.t()],
          read_tools: [String.t()],
          max_cue_age_s: non_neg_integer(),
          validator: String.t() | nil,
          interpreter: String.t() | nil,
          validator_env: [String.t()],
          idempotency_arg: String.t() | nil,
          unpinned: [String.t()],
          pin_args: %{optional(String.t()) => String.t() | number() | boolean()}
        }

  @doc """
  The allowed `[fermix_core.cues]` keys, which the config store uses to refuse a
  typo'd key at the parse boundary.
  """
  @spec config_keys() :: [atom()]
  def config_keys, do: @config_keys

  @doc "The most sources a surface may add to one settings file."
  @spec max_sources() :: pos_integer()
  def max_sources, do: @max_sources

  @doc "The most mandates a surface may add to one settings file."
  @spec max_mandates() :: pos_integer()
  def max_mandates, do: @max_mandates

  @doc "The secret fields a source of `kind` declares, in the order a surface lists them."
  @spec secret_fields(kind()) :: [secret_field()]
  def secret_fields(kind) when kind in @kinds, do: Map.fetch!(@secret_fields_by_kind, kind)

  @doc """
  The secrets `source` (a resolved source, or any map with its `kind`,
  `preset` and fields) cannot run without, in the order a surface lists them:
  a webhook's `secret`, a local push's `token`, and for a stream the `key` and
  `secret` its sign-in names (`Cues.JsonStream.secret_fields/1`).
  """
  @spec needed_secrets(map()) :: [secret_field()]
  def needed_secrets(%{kind: :stream} = source), do: JsonStream.secret_fields(source)

  def needed_secrets(%{kind: kind}) when kind in @kinds,
    do: @required_secret_by_kind |> Map.get(kind) |> List.wrap()

  @doc """
  The fields a source must name itself: those its kind, its webhook method
  (`verify`, the preset's when nil) and its preset need, less what `preset`
  (nil for none) fills. The one presence rule: a surface marks these before a
  save, and `normalize/1` refuses a section that leaves one out. Raises on a
  preset this daemon does not know.
  """
  @spec required_fields(kind(), String.t() | nil, atom() | String.t() | nil) :: [atom()]
  def required_fields(kind, preset, verify) when kind in @kinds do
    filled = preset_fill!(preset)
    method = verify || Map.get(filled, :verify)

    kind
    |> needed_fields(method, preset)
    |> Enum.reject(&Map.has_key?(filled, &1))
  end

  defp preset_fill!(nil), do: %{}

  defp preset_fill!(preset) when is_binary(preset) do
    case Presets.defaults(preset) do
      {:ok, defaults} -> defaults
      :error -> raise ArgumentError, "unknown preset #{inspect(preset)}"
    end
  end

  @doc "The fields a webhook names its identity by; it names one where its method needs one."
  @spec identity_fields() :: [atom()]
  def identity_fields, do: @identity_fields

  @doc """
  Whether a source still lacks the identity its method needs: a signed or
  shared-secret webhook names one of `identity_fields/0`, itself or through
  its preset. `fields` is what the source writes itself (a map or a keyword
  list). The one identity rule: a surface refuses before a save, and
  `normalize/1` refuses a section without one. Raises on an unknown preset.
  """
  @spec missing_identity?(kind(), String.t() | nil, atom() | String.t() | nil, map() | keyword()) ::
          boolean()
  def missing_identity?(kind, preset, verify, fields)
      when kind in @kinds and (is_map(fields) or is_list(fields)) do
    filled = Map.merge(preset_fill!(preset), Map.new(fields))
    identity_needed?(kind, verify || Map.get(filled, :verify)) and not identified?(filled)
  end

  # A signed or shared-secret webhook names the header that carries it and
  # how one delivery is told from another; a stream with no preset names where
  # each message keeps its id.
  defp needed_fields(kind, method, preset) do
    kind_needs(kind, preset) ++ method_needs(kind, method) ++ preset_needs(kind, preset)
  end

  # X accounts builds its own address from the handles it names.
  defp kind_needs(:feed, "x_accounts"), do: [:handles, :interval]
  defp kind_needs(kind, _preset), do: Map.fetch!(@required_by_kind, kind)

  defp method_needs(kind, method),
    do: if(identity_needed?(kind, method), do: [:header], else: [])

  defp identity_needed?(:webhook, method),
    do: method in [:hmac, :shared_secret, "hmac", "shared_secret"]

  defp identity_needed?(_kind, _method), do: false

  defp identified?(filled),
    do: Enum.any?(@identity_fields, &(Map.get(filled, &1) not in [nil, ""]))

  defp preset_needs(:stream, nil), do: [:id_path]
  defp preset_needs(_kind, _preset), do: []

  @doc "Whether `name` is a valid source ref or mandate name."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_pattern, name)
  def valid_name?(_name), do: false

  @doc """
  Validates a `[fermix_core.cues]` section (TOML-parsed map, or a keyword in the
  normalized or persisted shape) and returns the normalized keyword. Raises an
  `ArgumentError` naming the key on any bad value.
  """
  @spec normalize(nil | map() | keyword()) :: t()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    reject_unknown_keys!(config, @config_keys, "[fermix_core.cues]")

    []
    |> put_present(:enabled, normalize_boolean(lookup(config, :enabled), "cues.enabled"))
    |> put_present(
      :mandates_enabled,
      normalize_boolean(lookup(config, :mandates_enabled), "cues.mandates_enabled")
    )
    |> put_present(:door_port, normalize_door_port(lookup(config, :door_port)))
    |> put_present(:sources, normalize_table(lookup(config, :sources), :sources))
    |> put_present(:mandates, normalize_table(lookup(config, :mandates), :mandates))
  end

  def normalize(other) do
    raise ArgumentError, "[fermix_core.cues] must be a table, got: #{inspect(other)}"
  end

  @doc """
  The inverse of `normalize/1` for the persist path: every atom spelled the way
  the parser reads it back. Present keys only.
  """
  @spec to_keyword(t()) :: keyword()
  def to_keyword(config) when is_list(config) do
    Enum.map(config, fn
      {:sources, sources} -> {:sources, Map.new(sources, &persist_section/1)}
      {:mandates, mandates} -> {:mandates, Map.new(mandates, &persist_section/1)}
      {key, value} -> {key, value}
    end)
  end

  @doc "Whether `[fermix_core.cues] enabled` is set (the switch alone; see `FermixCore.Cues.enabled?/0`)."
  @spec enabled?(t()) :: boolean()
  def enabled?(config \\ current()), do: Keyword.get(config, :enabled, false)

  @doc "The global switch for unattended mandate calls (default on)."
  @spec mandates_enabled?(t()) :: boolean()
  def mandates_enabled?(config \\ current()), do: Keyword.get(config, :mandates_enabled, true)

  @doc "The loopback port the door listens on."
  @spec door_port(t()) :: :inet.port_number()
  def door_port(config \\ current()), do: Keyword.get(config, :door_port, @default_door_port)

  @doc "Every configured source, resolved through its preset, sorted by ref."
  @spec sources(t()) :: [source()]
  def sources(config \\ current()) do
    config
    |> Keyword.get(:sources, %{})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {ref, section} -> resolve_source(ref, section) end)
  end

  @doc "One source by ref, resolved through its preset."
  @spec source(String.t(), t()) :: {:ok, source()} | :error
  def source(ref, config \\ current()) when is_binary(ref) do
    case config |> Keyword.get(:sources, %{}) |> Map.fetch(ref) do
      {:ok, section} -> {:ok, resolve_source(ref, section)}
      :error -> :error
    end
  end

  @doc """
  Every mandate section, parsed, with the design's defaults filled in, sorted
  by name. Load checks are `Cues.Mandates`'.
  """
  @spec mandates(t()) :: [mandate()]
  def mandates(config \\ current()) do
    config
    |> Keyword.get(:mandates, %{})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, section} -> resolve_mandate(name, section) end)
  end

  @doc """
  The value of a source's secret field, read from the store its sentinel names
  (`cue_source:<ref>:<field>`).
  """
  @spec secret(String.t(), secret_field(), t()) :: {:ok, String.t()} | {:error, term()}
  def secret(ref, field, config \\ current()) when is_binary(ref) and field in @secret_fields do
    with {:ok, source} <- fetch_source(ref, config),
         {:ok, store} <- secret_store(source, field) do
      SecretWriter.get({:cue_source, ref, field}, store: store)
    end
  end

  defp current, do: Application.get_env(:fermix_core, :cues, [])

  defp fetch_source(ref, config) do
    case source(ref, config) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :unknown_source}
    end
  end

  defp secret_store(%{secrets: secrets}, field) do
    case Map.fetch(secrets, field) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, {:secret_not_configured, field}}
    end
  end

  # --- resolution (accessors) ---------------------------------------------

  defp resolve_source(ref, section) do
    {:ok, filled} = section |> Map.new() |> Presets.fill()

    secrets =
      for field <- @secret_fields,
          Map.has_key?(filled, field),
          into: %{},
          do: {field, store!(filled[field])}

    base = %{
      ref: ref,
      kind: Map.fetch!(filled, :kind),
      preset: Map.get(filled, :preset),
      enabled?: Map.get(filled, :enabled, true),
      daily_budget: Map.get(filled, :daily_budget, 0),
      item_types: Map.get(filled, :item_types, []),
      error_types: Map.get(filled, :error_types, []),
      interval: Map.get(filled, :interval),
      handles: Map.get(filled, :handles, []),
      id: Map.get(filled, :id),
      verify: Map.get(filled, :verify),
      secrets: secrets
    }

    source =
      Enum.reduce(@string_source_fields -- [:preset], base, fn field, acc ->
        Map.put(acc, field, Map.get(filled, field))
      end)

    Map.put(source, :missing_secret, missing_secret(source))
  end

  defp store!(sentinel) do
    {:ok, store} = SecretWriter.store_of_sentinel(sentinel)
    store
  end

  defp missing_secret(source),
    do: source |> needed_secrets() |> Enum.find(&(not Map.has_key?(source.secrets, &1)))

  defp resolve_mandate(name, section) do
    %{
      name: name,
      job: Keyword.fetch!(section, :job),
      enabled?: Keyword.get(section, :enabled, true),
      mode: Keyword.get(section, :mode, :approve),
      approve_within_s: duration_s(section, :approve_within, @default_approve_within_s),
      tools: Keyword.get(section, :tools, []),
      read_tools: Keyword.get(section, :read_tools, []),
      max_cue_age_s: duration_s(section, :max_cue_age, @default_max_cue_age_s),
      validator: Keyword.get(section, :validator),
      interpreter: Keyword.get(section, :interpreter),
      validator_env: Keyword.get(section, :validator_env, []),
      idempotency_arg: Keyword.get(section, :idempotency_arg),
      unpinned: Keyword.get(section, :unpinned, []),
      pin_args: Keyword.get(section, :pin_args, %{})
    }
  end

  defp duration_s(section, key, default) do
    case Keyword.fetch(section, key) do
      {:ok, "0"} -> 0
      {:ok, text} -> parse_duration!(text)
      :error -> default
    end
  end

  defp parse_duration!(text) do
    [_all, count, unit] = Regex.run(@duration_pattern, text)
    String.to_integer(count) * unit_seconds(unit)
  end

  defp unit_seconds("s"), do: 1
  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3_600

  # --- persist shape ---------------------------------------------------------

  defp persist_section({name, section}) do
    {name, Enum.map(section, fn {key, value} -> {key, persist_value(value)} end)}
  end

  defp persist_value(value) when is_atom(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp persist_value(value), do: value

  # --- tables ----------------------------------------------------------------

  defp normalize_table(nil, _table), do: nil

  defp normalize_table(sections, table) when is_map(sections) do
    normalized =
      Map.new(sections, fn {name, section} ->
        name = table_name!(name, table)
        {name, normalize_section(table, name, section)}
      end)

    if normalized == %{}, do: nil, else: normalized
  end

  defp normalize_table(other, table) do
    raise ArgumentError,
          "cues.#{table} must be a table of [fermix_core.cues.#{table}.<name>] sections, " <>
            "got: #{inspect(other)}"
  end

  defp table_name!(name, table) do
    name = if is_atom(name), do: Atom.to_string(name), else: name

    if valid_name?(name) do
      name
    else
      raise ArgumentError,
            "cues.#{table}: the name #{inspect(name)} must be lowercase letters, digits and " <>
              "hyphens, start with a letter or digit, and be at most 64 characters"
    end
  end

  defp normalize_section(:sources, ref, section) when is_map(section) or is_list(section) do
    reject_unknown_keys!(section, @source_keys, "[fermix_core.cues.sources.#{ref}]")

    normalized =
      Enum.reduce(@source_keys, [], fn key, acc ->
        put_present(acc, key, source_value(key, lookup(section, key), ref))
      end)

    check_source!(ref, normalized)
    normalized
  end

  defp normalize_section(:mandates, name, section) when is_map(section) or is_list(section) do
    reject_unknown_keys!(section, @mandate_keys, "[fermix_core.cues.mandates.#{name}]")

    normalized =
      Enum.reduce(@mandate_keys, [], fn key, acc ->
        put_present(acc, key, mandate_value(key, lookup(section, key), name))
      end)

    unless Keyword.has_key?(normalized, :job) do
      raise ArgumentError,
            "cues.mandates.#{name}.job is required: the task's id, as list_jobs shows it"
    end

    normalized
  end

  defp normalize_section(table, name, other) do
    raise ArgumentError, "cues.#{table}.#{name} must be a table, got: #{inspect(other)}"
  end

  # --- source values -----------------------------------------------------------

  defp source_value(_key, nil, _ref), do: nil
  defp source_value(:kind, value, ref), do: enum!(value, @kinds, "cues.sources.#{ref}.kind")

  defp source_value(:enabled, value, ref),
    do: normalize_boolean(value, "cues.sources.#{ref}.enabled")

  defp source_value(:verify, value, ref),
    do: enum!(value, @verify_methods, "cues.sources.#{ref}.verify")

  defp source_value(:id, value, ref), do: enum!(value, @id_choices, "cues.sources.#{ref}.id")

  defp source_value(:interval, value, ref),
    do: integer_at_least!(value, @min_interval_s, "cues.sources.#{ref}.interval", "seconds")

  defp source_value(:daily_budget, value, ref),
    do: integer_at_least!(value, 0, "cues.sources.#{ref}.daily_budget", "items per UTC day")

  defp source_value(:handles, value, ref) do
    case XAccounts.handles(value) do
      {:ok, handles} -> handles
      {:error, words} -> raise ArgumentError, "invalid cues.sources.#{ref}.handles: #{words}"
    end
  end

  defp source_value(key, value, ref) when key in @list_source_fields,
    do: string_list!(value, "cues.sources.#{ref}.#{key}")

  defp source_value(key, value, ref) when key in @secret_fields, do: sentinel!(value, ref, key)
  defp source_value(key, value, ref), do: string!(value, "cues.sources.#{ref}.#{key}")

  defp check_source!(ref, normalized) do
    filled =
      case normalized |> Map.new() |> Presets.fill() do
        {:ok, filled} -> filled
        {:error, message} -> raise ArgumentError, "cues.sources.#{ref}: #{message}"
      end

    kind =
      Map.get(filled, :kind) ||
        raise ArgumentError,
              "cues.sources.#{ref} needs a kind (stream, feed, webhook or local_push) or a preset"

    check_field_kinds!(ref, kind, Map.keys(filled))
    check_required!(ref, kind, filled)
    check_identity!(ref, kind, filled)
    check_webhook!(ref, kind, filled)
    check_x_accounts!(ref, filled)
    check_url_scheme!(ref, kind, Map.get(filled, :url))
    check_item_paths!(ref, filled)
    check_general_stream!(ref, kind, filled)
  end

  # X accounts makes its address from its handles, and only it takes handles.
  defp check_x_accounts!(ref, %{preset: "x_accounts", url: _url}) do
    raise ArgumentError,
          "cues.sources.#{ref}.url is not used: x_accounts builds its own address from handles"
  end

  defp check_x_accounts!(_ref, %{preset: "x_accounts"}), do: :ok

  defp check_x_accounts!(ref, %{handles: _handles}) do
    raise ArgumentError,
          ~s(cues.sources.#{ref}.handles applies only to preset = "x_accounts")
  end

  defp check_x_accounts!(_ref, _filled), do: :ok

  # Fermix reads sources only over an encrypted connection: a feed over https,
  # a stream over wss (a WebSocket).
  @url_schemes %{feed: ["https://"], stream: ["wss://"]}

  defp check_url_scheme!(_ref, _kind, nil), do: :ok

  defp check_url_scheme!(ref, kind, url) do
    schemes = Map.get(@url_schemes, kind, [])

    unless schemes == [] or String.starts_with?(url, schemes) do
      raise ArgumentError,
            "cues.sources.#{ref}.url must start with #{Enum.join(schemes, " or ")}"
    end
  end

  # The general WebSocket source's headers, messages and paths are
  # `Cues.JsonStream`'s rules.
  defp check_general_stream!(ref, :stream, filled) do
    case JsonStream.check_config(filled) do
      :ok -> :ok
      {:error, field, words} -> raise ArgumentError, "cues.sources.#{ref}.#{field} #{words}"
    end
  end

  defp check_general_stream!(_ref, _kind, _filled), do: :ok

  # A webhook's method, identity and paths are `Cues.Webhook`'s rules.
  defp check_webhook!(ref, :webhook, filled) do
    case Webhook.check_config(filled) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, "cues.sources.#{ref}: #{message}"
    end
  end

  defp check_webhook!(_ref, _kind, _filled), do: :ok

  defp check_item_paths!(ref, filled) do
    if Map.has_key?(filled, :items_path) and not Map.has_key?(filled, :id_path) do
      raise ArgumentError, "cues.sources.#{ref}.items_path needs id_path, where each item's id is"
    end
  end

  defp check_field_kinds!(ref, kind, fields) do
    Enum.each(fields, fn field ->
      kinds = Map.get(@field_kinds, field, @kinds)

      unless kind in kinds do
        raise ArgumentError,
              "cues.sources.#{ref}.#{field} applies only to #{Enum.join(kinds, " and ")} " <>
                "sources, and this one is #{kind}"
      end
    end)
  end

  defp check_required!(ref, kind, filled) do
    needed = needed_fields(kind, Map.get(filled, :verify), Map.get(filled, :preset))

    case Enum.reject(needed, &(Map.get(filled, &1) not in [nil, "", []])) do
      [] ->
        :ok

      missing ->
        raise ArgumentError,
              "cues.sources.#{ref} is a #{kind} source and needs " <>
                Enum.map_join(missing, " and ", &needed_words/1)
    end
  end

  defp check_identity!(ref, kind, filled) do
    if identity_needed?(kind, Map.get(filled, :verify)) and not identified?(filled) do
      raise ArgumentError,
            ~s(cues.sources.#{ref}: needs an identity: id_header, id_path or id = "content_hash")
    end
  end

  defp needed_words(:header), do: "header, the request header that carries the signature"
  defp needed_words(field), do: Atom.to_string(field)

  defp sentinel!(value, ref, field) do
    if SecretWriter.sentinel?(value) do
      value
    else
      # The value is never repeated: it may be the secret itself.
      raise ArgumentError,
            ~s(cues.sources.#{ref}.#{field} must be "@keyring" or "@file"; ) <>
              store_words(ref, field)
    end
  end

  # Where a release stores each secret field: Fermix makes the token and the
  # webhook address; the owner types a key or a secret.
  defp store_words(_ref, :token), do: "make a token with New token in the source's settings"

  defp store_words(_ref, :path_secret),
    do: "make the address with Generate URL in the source's settings"

  defp store_words(ref, field) do
    "type the value into the source's settings (the setup page's Cues tab or the app's " <>
      "Cues pane), or on a host without a browser run " <>
      "fermix settings secret set cue_source:#{ref}:#{field}"
  end

  # --- mandate values ----------------------------------------------------------

  defp mandate_value(_key, nil, _name), do: nil

  defp mandate_value(:enabled, value, name),
    do: normalize_boolean(value, "cues.mandates.#{name}.enabled")

  defp mandate_value(:mode, value, name), do: enum!(value, @modes, "cues.mandates.#{name}.mode")

  defp mandate_value(:approve_within, value, name) do
    label = "cues.mandates.#{name}.approve_within"
    seconds = duration!(value, label, false)

    if seconds > @max_approve_within_s do
      raise ArgumentError,
            "#{label} #{inspect(value)} is longer than 24h; a proposal waits at most 24h"
    end

    value
  end

  defp mandate_value(:max_cue_age, value, name) do
    _seconds = duration!(value, "cues.mandates.#{name}.max_cue_age", true)
    value
  end

  defp mandate_value(key, value, name)
       when key in [:tools, :read_tools, :validator_env, :unpinned],
       do: string_list!(value, "cues.mandates.#{name}.#{key}")

  defp mandate_value(:pin_args, value, name),
    do: pin_args!(value, "cues.mandates.#{name}.pin_args")

  defp mandate_value(key, value, name), do: string!(value, "cues.mandates.#{name}.#{key}")

  defp duration!(value, label, zero_allowed?) do
    cond do
      zero_allowed? and value == "0" ->
        0

      is_binary(value) and Regex.match?(@duration_pattern, value) ->
        parse_duration!(value)

      true ->
        zero = if zero_allowed?, do: ", or \"0\" for none", else: ""

        raise ArgumentError,
              "invalid #{label} #{inspect(value)}; expected a duration such as \"30s\", " <>
                "\"15m\" or \"2h\"#{zero}"
    end
  end

  defp pin_args!(value, label) when is_map(value) do
    pins = Map.new(value, fn {key, pin} -> pin_entry!(key, pin, label) end)
    if pins == %{}, do: nil, else: pins
  end

  defp pin_args!(value, label) do
    raise ArgumentError,
          "invalid #{label} #{inspect(value)}; expected a table, written as its own section " <>
            "[fermix_core.cues.mandates.<name>.pin_args] with one key = value per line"
  end

  defp pin_entry!(key, pin, label) do
    key = if is_atom(key), do: Atom.to_string(key), else: key

    unless is_binary(key) and Regex.match?(@pin_key_pattern, key) do
      raise ArgumentError, "invalid #{label} key #{inspect(key)}; expected an argument name"
    end

    {key, pin_value!(pin, "#{label}.#{key}")}
  end

  defp pin_value!(pin, _label) when is_binary(pin) or is_boolean(pin), do: pin
  defp pin_value!(pin, _label) when is_integer(pin) and pin >= 0, do: pin

  defp pin_value!(pin, label) when is_float(pin) do
    if Regex.match?(@float_text_pattern, :erlang.float_to_binary(pin, [:short])) do
      pin
    else
      raise ArgumentError, "invalid #{label} #{inspect(pin)}; write the number in plain decimals"
    end
  end

  defp pin_value!(pin, label) do
    raise ArgumentError,
          "invalid #{label} #{inspect(pin)}; expected a string, a boolean or a non-negative " <>
            "number (quote a negative number)"
  end

  # --- shared validators -------------------------------------------------------

  defp normalize_door_port(nil), do: nil
  defp normalize_door_port(port) when is_integer(port) and port in @door_ports, do: port

  defp normalize_door_port(port) do
    raise ArgumentError,
          "invalid cues.door_port #{inspect(port)}; expected an integer from 1024 to 65535"
  end

  defp normalize_boolean(nil, _label), do: nil
  defp normalize_boolean(value, _label) when is_boolean(value), do: value

  defp normalize_boolean(value, label) do
    raise ArgumentError, "invalid #{label} #{inspect(value)}; expected boolean true or false"
  end

  defp enum!(value, allowed, label) when is_atom(value) and not is_boolean(value) do
    if value in allowed, do: value, else: enum_error!(value, allowed, label)
  end

  defp enum!(value, allowed, label) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> enum_error!(value, allowed, label)
      atom -> atom
    end
  end

  defp enum!(value, allowed, label), do: enum_error!(value, allowed, label)

  defp enum_error!(value, allowed, label) do
    raise ArgumentError,
          "invalid #{label} #{inspect(value)}; expected one of: #{Enum.join(allowed, ", ")}"
  end

  defp integer_at_least!(value, min, _label, _unit) when is_integer(value) and value >= min,
    do: value

  defp integer_at_least!(value, min, label, unit) do
    raise ArgumentError,
          "invalid #{label} #{inspect(value)}; expected an integer at least #{min} (#{unit})"
  end

  defp string!(value, _label) when is_binary(value) and value != "", do: value

  defp string!(value, label) do
    raise ArgumentError, "invalid #{label} #{inspect(value)}; expected a non-empty string"
  end

  defp string_list!(values, label) when is_list(values) do
    Enum.map(values, fn
      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError,
              "invalid #{label} entry #{inspect(value)}; expected a non-empty string"
    end)
  end

  defp string_list!(values, label) do
    raise ArgumentError, "invalid #{label} #{inspect(values)}; expected a list of strings"
  end

  defp reject_unknown_keys!(config, allowed, section) do
    allowed_names = MapSet.new(allowed, &Atom.to_string/1)

    unknown =
      config
      |> keys()
      |> Enum.reject(&MapSet.member?(allowed_names, &1))
      |> Enum.sort()

    if unknown != [] do
      raise ArgumentError, """
      config.toml #{section} has unknown key(s): #{Enum.join(unknown, ", ")}.

      Allowed keys: #{Enum.map_join(allowed, ", ", &Atom.to_string/1)}.
      Remove or fix the key(s); the daemon will not boot until this is fixed.
      """
    end
  end

  defp keys(config) when is_map(config), do: config |> Map.keys() |> Enum.map(&to_string/1)

  defp keys(config) when is_list(config),
    do: Enum.map(config, fn {key, _value} -> to_string(key) end)

  defp lookup(config, key) when is_map(config),
    do: Map.get(config, Atom.to_string(key), Map.get(config, key))

  defp lookup(config, key) when is_list(config), do: Keyword.get(config, key)

  defp put_present(keyword, _key, nil), do: keyword
  defp put_present(keyword, key, value), do: keyword ++ [{key, value}]
end
