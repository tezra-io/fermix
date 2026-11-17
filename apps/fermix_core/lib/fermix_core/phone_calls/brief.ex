defmodule FermixCore.PhoneCalls.Brief do
  @moduledoc """
  A phone call's mandate (M94 §6, "Brief fields"; §3, "Who may be called"):
  who is called and why, what finishes the task, what the call must not agree
  to, what it may share, which backend tools it may use, and the number it
  calls from.

  `new/2` is the one way to build one. The model supplies the task, as the
  tool's string-keyed parameters; the server supplies its own facts in `opts`:
  the configured caller number and the clock. The model never supplies
  approval, credentials, a provider or callback URL, the caller number, the
  model, the voice or an instruction override: such a key is rejected by name
  (`:server_owned_field`), and any other unknown key too (`:unknown_field`),
  never ignored. Every field is bounded in size and count (`bounds/0`).

  Fermix calls two kinds of destination, the owner's own phone and a business,
  both in a US state or DC. The kind is the brief's recorded statement, covered
  by the owner's authorization, not a fact Fermix can check. A private person,
  a kind the brief does not know, a number outside the US states and DC, and
  an emergency, service or other special number are refused
  (`{:refused, reason, sentence}`), before any field problem is reported,
  because fixing a field cannot make such a call allowed. Otherwise every
  field problem is reported at once (`{:invalid_brief, problems}`), one per
  field. Neither result consumes an attempt; that is the caller's to prove.

  Times are absolute and local to the destination's zone: a date
  (`2026-11-21`) or a wall-clock time (`2026-11-21T19:30`), never a relative
  word or an offset, and not already past. Free text (the goal, the criteria)
  is not parsed for dates: no code reads natural language here.

  `hash/1` is a sha256 over a canonical encoding (sorted keys, the schema
  version inside), so one mandate hashes the same across restarts.
  `to_map/1` and `from_map/1` are the JSON-safe round trip the ledger stores;
  `from_map/1` checks the stored shape, not the clock or today's calling
  policy, so a brief admitted yesterday still reads back.
  """

  alias FermixCore.Clock
  alias FermixCore.PhoneCalls.UsNumbers

  @schema 1

  @bounds %{
    max_fields: 32,
    contact_name_bytes: 120,
    number_source_bytes: 300,
    goal_bytes: 1_000,
    item_bytes: 300,
    completion_criteria: 8,
    list_items: 8,
    shareable_facts: 12,
    label_bytes: 80,
    fact_value_bytes: 500,
    tool_grants: 8,
    times: 8,
    timezone_bytes: 64,
    language_bytes: 35
  }

  # Each model-supplied field: its kind, and its default, or `:required`.
  @fields [
    destination: {:destination, :required},
    destination_kind: {:kind, :required},
    number_source: {{:line, @bounds.number_source_bytes}, :required},
    contact_name: {{:line, @bounds.contact_name_bytes}, :required},
    timezone: {:timezone, :required},
    goal: {{:text, @bounds.goal_bytes}, :required},
    completion_criteria: {{:list, 1, @bounds.completion_criteria}, :required},
    must_not_commit: {{:list, 0, @bounds.list_items}, []},
    alternatives: {{:list, 0, @bounds.list_items}, []},
    shareable_facts: {:facts, []},
    tool_grants: {:tool_grants, []},
    times: {:times, []},
    opening_language: {:language, "en"}
  ]

  @model_keys for {name, _spec} <- @fields, do: Atom.to_string(name)
  @stored_keys ["schema", "caller_number" | @model_keys]
  @server_owned_keys ~w(approved approval authorization caller_number sip_username
                        sip_password password trunk provider_url callback_url webhook_url
                        instructions instruction_override system_prompt prompt model voice
                        api_key)
  @key_report_chars 64

  @kinds %{"owner" => :owner, "business" => :business}
  @refused_kind "private_individual"
  @refusal_reasons [
    :private_individual,
    :unknown_destination_kind,
    :destination_not_us,
    :emergency_or_special_number
  ]

  @e164 ~r/\A\+[1-9][0-9]{1,14}\z/
  @tool_name ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @language_tag ~r/\A[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8}){0,3}\z/
  @local_date ~r/\A\d{4}-\d{2}-\d{2}\z/
  @local_time ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/
  @line_controls ~r/[\x00-\x1F\x7F]/
  @text_controls ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

  @enforce_keys [:caller_number | Keyword.keys(@fields)]
  defstruct @enforce_keys

  @type kind :: :owner | :business
  @type refusal ::
          :private_individual
          | :unknown_destination_kind
          | :destination_not_us
          | :emergency_or_special_number
  @type problem :: {atom(), atom() | String.t()}

  @type t :: %__MODULE__{
          destination: String.t(),
          destination_kind: kind(),
          number_source: String.t(),
          contact_name: String.t(),
          timezone: String.t(),
          goal: String.t(),
          completion_criteria: [String.t(), ...],
          must_not_commit: [String.t()],
          alternatives: [String.t()],
          shareable_facts: [%{label: String.t(), value: String.t()}],
          tool_grants: [String.t()],
          times: [%{label: String.t(), at: String.t()}],
          opening_language: String.t(),
          caller_number: String.t()
        }

  @doc """
  The mandate from the model's task parameters and the server's facts:
  `opts[:caller_number]`, the configured caller number, and `opts[:now]`, a
  `DateTime`. Raises when either server fact is missing or unsound.
  """
  @spec new(map(), keyword()) ::
          {:ok, t()}
          | {:error, {:invalid_brief, [problem(), ...]}}
          | {:error, {:refused, refusal(), String.t()}}
  def new(params, opts) when is_map(params) and is_list(opts) do
    context = server_facts!(opts)

    with :ok <- within_field_count(params),
         :ok <- refusal(params) do
      case build(params, context) do
        {:ok, brief} -> {:ok, brief}
        {:error, problems} -> {:error, {:invalid_brief, problems}}
      end
    end
  end

  @doc "A brief as the ledger stored it (`to_map/1`, through JSON)."
  @spec from_map(map()) :: {:ok, t()} | {:error, {:invalid_stored_brief, [problem(), ...]}}
  def from_map(map) when is_map(map) do
    result =
      with :ok <- within_field_count(map), do: build(map, %{mode: :stored, now: nil})

    case result do
      {:ok, brief} -> {:ok, brief}
      {:error, {:invalid_brief, problems}} -> {:error, {:invalid_stored_brief, problems}}
      {:error, problems} -> {:error, {:invalid_stored_brief, problems}}
    end
  end

  @doc "The brief as a JSON-safe, string-keyed map, with its schema version."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = brief) do
    %{
      "schema" => @schema,
      "destination" => brief.destination,
      "destination_kind" => Atom.to_string(brief.destination_kind),
      "number_source" => brief.number_source,
      "contact_name" => brief.contact_name,
      "timezone" => brief.timezone,
      "goal" => brief.goal,
      "completion_criteria" => brief.completion_criteria,
      "must_not_commit" => brief.must_not_commit,
      "alternatives" => brief.alternatives,
      "shareable_facts" =>
        Enum.map(brief.shareable_facts, &%{"label" => &1.label, "value" => &1.value}),
      "tool_grants" => brief.tool_grants,
      "times" => Enum.map(brief.times, &%{"label" => &1.label, "at" => &1.at}),
      "opening_language" => brief.opening_language,
      "caller_number" => brief.caller_number
    }
  end

  @doc "The canonical encoding `hash/1` digests: `to_map/1` as JSON with every key sorted."
  @spec canonical_json(t()) :: String.t()
  def canonical_json(%__MODULE__{} = brief), do: brief |> to_map() |> ordered() |> Jason.encode!()

  @doc "The mandate's sha256, lowercase hex."
  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = brief),
    do: :sha256 |> :crypto.hash(canonical_json(brief)) |> Base.encode16(case: :lower)

  @doc "The destination kinds a brief may name."
  @spec destination_kinds() :: [String.t(), ...]
  def destination_kinds, do: Map.keys(@kinds)

  @doc "Every refusal `new/2` returns."
  @spec refusal_reasons() :: [refusal(), ...]
  def refusal_reasons, do: @refusal_reasons

  @doc "The size and count bounds on a brief's fields."
  @spec bounds() :: %{atom() => pos_integer()}
  def bounds, do: @bounds

  @doc "The sentence a refusal carries."
  @spec refusal_sentence(refusal()) :: String.t()
  def refusal_sentence(:private_individual),
    do: "Fermix calls only the owner's own phone or a business, never a private person."

  def refusal_sentence(:unknown_destination_kind),
    do:
      "Fermix calls only the owner's own phone or a business, and the brief must say which " <>
        "this number is."

  def refusal_sentence(:destination_not_us),
    do: "Fermix calls only numbers in the 50 US states and DC, and this number is outside them."

  def refusal_sentence(:emergency_or_special_number),
    do: "Fermix never calls an emergency, service, toll-free, premium or other special number."

  # -- the server's facts and the refusals ---------------------------------------

  defp server_facts!(opts) do
    caller = Keyword.get(opts, :caller_number)
    now = Keyword.get(opts, :now)

    unless is_binary(caller) and UsNumbers.classify(caller) == :ok do
      raise ArgumentError,
            "Brief.new/2 needs opts[:caller_number], a US number, got: #{inspect(caller)}"
    end

    unless match?(%DateTime{}, now) do
      raise ArgumentError, "Brief.new/2 needs opts[:now], a DateTime, got: #{inspect(now)}"
    end

    %{mode: :admission, now: now, caller_number: caller}
  end

  defp within_field_count(params) when map_size(params) > @bounds.max_fields,
    do: {:error, {:invalid_brief, [{:params, :too_many_fields}]}}

  defp within_field_count(_params), do: :ok

  defp refusal(params) do
    with :ok <- kind_refusal(Map.get(params, "destination_kind")),
         do: destination_refusal(Map.get(params, "destination"))
  end

  # An absent, blank or non-string kind is a brief problem, reported by `build/2`.
  defp kind_refusal(kind) when is_binary(kind) do
    kind = normal_kind(kind)

    cond do
      kind == "" or Map.has_key?(@kinds, kind) -> :ok
      kind == @refused_kind -> refused(:private_individual)
      true -> refused(:unknown_destination_kind)
    end
  end

  defp kind_refusal(_kind), do: :ok

  defp destination_refusal(number) when is_binary(number) do
    case UsNumbers.classify(String.trim(number)) do
      {:error, reason} when reason in [:destination_not_us, :emergency_or_special_number] ->
        refused(reason)

      _ok_or_malformed ->
        :ok
    end
  end

  defp destination_refusal(_number), do: :ok

  defp refused(reason), do: {:error, {:refused, reason, refusal_sentence(reason)}}

  # -- building ---------------------------------------------------------------------

  defp build(params, context) do
    {values, field_problems} = fields(params, context)
    {values, caller_problems} = caller_number(values, params, context)

    problems =
      key_problems(params, context.mode) ++
        schema_problems(params, context.mode) ++ field_problems ++ caller_problems

    case problems ++ cross_problems(values) do
      [] -> {:ok, struct!(__MODULE__, values)}
      all -> {:error, all}
    end
  end

  # Every field but `times`, which reads the zone the others settled.
  defp fields(params, context) do
    {values, problems} =
      Enum.reduce(@fields, {%{}, []}, fn
        {:times, _spec}, acc -> acc
        {name, spec}, acc -> put_field(acc, name, field(spec, params, name, context))
      end)

    zone = Map.get(values, :timezone)
    times = field(Keyword.fetch!(@fields, :times), params, :times, Map.put(context, :zone, zone))
    {values, problems} = put_field({values, problems}, :times, times)
    {values, Enum.reverse(problems)}
  end

  defp put_field({values, problems}, name, {:ok, value}),
    do: {Map.put(values, name, value), problems}

  defp put_field({values, problems}, name, {:error, reason}),
    do: {values, [{name, reason} | problems]}

  defp field({kind, default}, params, name, context) do
    case Map.fetch(params, Atom.to_string(name)) do
      {:ok, value} -> value(kind, value, context)
      :error -> absent(default, context.mode)
    end
  end

  # A stored brief holds every field, so none takes its default there.
  defp absent(:required, _mode), do: {:error, :missing}
  defp absent(_default, :stored), do: {:error, :missing}
  defp absent(default, :admission), do: {:ok, default}

  # The caller number is the server's at admission and the stored one after.
  defp caller_number(values, _params, %{mode: :admission, caller_number: caller}),
    do: {Map.put(values, :caller_number, caller), []}

  defp caller_number(values, params, %{mode: :stored}) do
    case Map.fetch(params, "caller_number") do
      {:ok, number} when is_binary(number) -> stored_caller(values, e164(number))
      {:ok, _number} -> {values, [{:caller_number, :not_a_string}]}
      :error -> {values, [{:caller_number, :missing}]}
    end
  end

  defp stored_caller(values, {:ok, number}), do: {Map.put(values, :caller_number, number), []}
  defp stored_caller(values, {:error, reason}), do: {values, [{:caller_number, reason}]}

  defp key_problems(params, mode) do
    allowed = if mode == :admission, do: @model_keys, else: @stored_keys

    params
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(&key_problem(&1, allowed, mode))
    |> Enum.uniq()
  end

  defp key_problem(key, _allowed, _mode) when not is_binary(key), do: [{:params, :non_string_key}]

  defp key_problem(key, allowed, mode) do
    cond do
      key in allowed -> []
      mode == :admission and key in @server_owned_keys -> [{:server_owned_field, key}]
      true -> [{:unknown_field, String.slice(key, 0, @key_report_chars)}]
    end
  end

  # A stored brief names the schema it was written in; a model's never does.
  defp schema_problems(%{"schema" => @schema}, :stored), do: []
  defp schema_problems(_params, :stored), do: [{:schema, :unsupported}]
  defp schema_problems(_params, :admission), do: []

  defp cross_problems(%{destination: same, caller_number: same}),
    do: [{:destination, :same_as_caller_number}]

  defp cross_problems(_values), do: []

  # -- one field's value ------------------------------------------------------------

  # At admission `refusal/1` has already refused a number outside the US states
  # and DC, so only a malformed one is left to report here.
  defp value(:destination, number, %{mode: :admission}) when is_binary(number) do
    number = String.trim(number)
    with :ok <- UsNumbers.classify(number), do: {:ok, number}
  end

  defp value(:destination, number, %{mode: :stored}) when is_binary(number), do: e164(number)

  defp value(:kind, kind, _context) when is_binary(kind) do
    kind = normal_kind(kind)

    case Map.fetch(@kinds, kind) do
      {:ok, atom} -> {:ok, atom}
      :error when kind == "" -> {:error, :blank}
      :error -> {:error, :unknown_destination_kind}
    end
  end

  defp value({:line, max}, text, _context), do: text(text, max, @line_controls)
  defp value({:text, max}, text, _context), do: text(text, max, @text_controls)

  defp value(:timezone, zone, _context) do
    with {:ok, zone} <- text(zone, @bounds.timezone_bytes, @line_controls) do
      case Clock.validate_zone(zone) do
        {:ok, zone} -> {:ok, zone}
        {:error, _invalid} -> {:error, :unknown_timezone}
      end
    end
  end

  defp value({:list, min, max}, items, _context), do: list(items, min, max, &item/1)
  defp value(:facts, facts, _context), do: list(facts, 0, @bounds.shareable_facts, &fact/1)
  defp value(:times, times, context), do: list(times, 0, @bounds.times, &time(&1, context))
  defp value(:tool_grants, grants, _context), do: tool_grants(grants)

  defp value(:language, tag, _context) do
    with {:ok, tag} <- text(tag, @bounds.language_bytes, @line_controls) do
      if Regex.match?(@language_tag, tag), do: {:ok, tag}, else: {:error, :not_a_language_tag}
    end
  end

  defp value(_kind, _value, _context), do: {:error, :not_a_string}

  defp e164(number),
    do: if(Regex.match?(@e164, number), do: {:ok, number}, else: {:error, :not_e164})

  defp normal_kind(kind), do: kind |> String.trim() |> String.downcase()

  # -- text and lists ---------------------------------------------------------------

  defp text(value, _max, _controls) when not is_binary(value), do: {:error, :not_a_string}

  defp text(value, max, controls) do
    if String.valid?(value),
      do: trimmed(String.trim(value), max, controls),
      else: {:error, :invalid_utf8}
  end

  defp trimmed("", _max, _controls), do: {:error, :blank}
  defp trimmed(text, max, _controls) when byte_size(text) > max, do: {:error, :too_long}

  defp trimmed(text, _max, controls),
    do: if(Regex.match?(controls, text), do: {:error, :control_characters}, else: {:ok, text})

  defp list(items, _min, _max, _each) when not is_list(items), do: {:error, :not_a_list}
  defp list(items, _min, max, _each) when length(items) > max, do: {:error, :too_many}
  defp list(items, min, _max, _each) when length(items) < min, do: {:error, :empty}

  # The first item's problem is the field's.
  defp list(items, _min, _max, each) do
    case Enum.reduce_while(items, [], &collect(&1, &2, each)) do
      {:error, reason} -> {:error, reason}
      values -> {:ok, Enum.reverse(values)}
    end
  end

  defp collect(item, values, each) do
    case each.(item) do
      {:ok, value} -> {:cont, [value | values]}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp item(item) when not is_binary(item), do: {:error, :item_not_a_string}

  defp item(item) do
    case text(item, @bounds.item_bytes, @text_controls) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, item_reason(reason)}
    end
  end

  defp item_reason(:blank), do: :blank_item
  defp item_reason(:too_long), do: :item_too_long
  defp item_reason(:control_characters), do: :item_control_characters
  defp item_reason(:invalid_utf8), do: :item_invalid_utf8

  defp fact(%{"label" => label, "value" => value} = fact) when map_size(fact) == 2 do
    with {:ok, label} <- text(label, @bounds.label_bytes, @line_controls),
         {:ok, value} <- text(value, @bounds.fact_value_bytes, @text_controls) do
      {:ok, %{label: label, value: value}}
    else
      {:error, _reason} -> {:error, :invalid_fact}
    end
  end

  defp fact(_fact), do: {:error, :invalid_fact}

  defp tool_grants(grants) do
    with {:ok, names} <- list(grants, 0, @bounds.tool_grants, &tool_name/1) do
      if names == Enum.uniq(names), do: {:ok, names}, else: {:error, :duplicate}
    end
  end

  defp tool_name(name) when is_binary(name) do
    if Regex.match?(@tool_name, name), do: {:ok, name}, else: {:error, :invalid_tool_name}
  end

  defp tool_name(_name), do: {:error, :invalid_tool_name}

  # -- absolute local times -----------------------------------------------------------

  defp time(%{"label" => label, "at" => at} = entry, context) when map_size(entry) == 2 do
    with {:ok, label} <- time_label(label),
         {:ok, at} <- local_time(at, context) do
      {:ok, %{label: label, at: at}}
    end
  end

  defp time(_entry, _context), do: {:error, :invalid_time_entry}

  defp time_label(label) do
    case text(label, @bounds.label_bytes, @line_controls) do
      {:ok, label} -> {:ok, label}
      {:error, _reason} -> {:error, :invalid_time_entry}
    end
  end

  defp local_time(at, context) when is_binary(at) do
    cond do
      Regex.match?(@local_date, at) ->
        local_date(Date.from_iso8601(at), at, context)

      Regex.match?(@local_time, at) ->
        wall_time(NaiveDateTime.from_iso8601(at <> ":00"), at, context)

      true ->
        {:error, :not_a_local_time}
    end
  end

  defp local_time(_at, _context), do: {:error, :not_a_local_time}

  defp local_date({:error, _reason}, _at, _context), do: {:error, :not_a_local_time}

  defp local_date({:ok, date}, at, context) do
    if checks_clock?(context) and past_day?(date, context),
      do: {:error, :in_the_past},
      else: {:ok, at}
  end

  defp wall_time({:error, _reason}, _at, _context), do: {:error, :not_a_local_time}

  defp wall_time({:ok, naive}, at, context) do
    cond do
      not checks_clock?(context) -> {:ok, at}
      past_day?(NaiveDateTime.to_date(naive), context) -> {:error, :in_the_past}
      true -> in_zone(DateTime.from_naive(naive, context.zone), at, context.now)
    end
  end

  defp in_zone({:ok, at_time}, at, now) do
    if DateTime.compare(at_time, now) == :lt, do: {:error, :in_the_past}, else: {:ok, at}
  end

  defp in_zone({:gap, _before, _after}, _at, _now), do: {:error, :nonexistent_local_time}
  defp in_zone({:ambiguous, _first, _second}, _at, _now), do: {:error, :ambiguous_local_time}
  defp in_zone({:error, _reason}, _at, _now), do: {:error, :not_a_local_time}

  # The clock is checked only at admission, and only once the zone is known.
  defp checks_clock?(%{mode: :admission, zone: zone}) when is_binary(zone), do: true
  defp checks_clock?(_context), do: false

  defp past_day?(date, %{now: now, zone: zone}),
    do: Date.compare(date, now |> DateTime.shift_zone!(zone) |> DateTime.to_date()) == :lt

  # -- canonical encoding -------------------------------------------------------------

  defp ordered(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value
end
