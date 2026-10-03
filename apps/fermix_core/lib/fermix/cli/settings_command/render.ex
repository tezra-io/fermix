defmodule Fermix.CLI.SettingsCommand.Render do
  @moduledoc """
  Human and JSON output for `fermix settings`, with no side effects.

  Each renderer validates the reply it reads and answers `{:ok, iodata}` or
  `{:error, :invalid_reply}`, so a malformed reply is refused rather than half
  printed. `error/2` maps a failure to `{exit_code, sentence}`; the caller adds
  the `fermix settings ...:` prefix.

  Every daemon-sourced string shown to a person is scrubbed of C0, DEL and C1
  control characters (U+009B is a one-codepoint CSI a terminal honours like
  ESC-[) and truncated. `--json` output is never scrubbed or truncated: it is
  JSON-encoded. The scrubber is a deliberate third copy beside `devices` and
  `pair`, so neighbouring code stays untouched.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.HomeOwner

  @control_chars ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @field_max 200
  # `info` is the paragraph `--info` exists to show, so it gets a longer bound.
  @paragraph_max 2_000

  @not_running "the Fermix daemon is not running, and settings change only through it.\n" <>
                 "Start it with `fermix start`. If setup never finished, run `fermix setup` first."
  @external_change "config.toml changed outside Fermix, so nothing was saved.\n" <>
                     "Load it with `fermix settings reload`, then retry."
  @file_store_remedy "On a machine with no desktop session to unlock it, " <>
                       "store secrets in the file store instead:\n" <>
                       "  fermix settings set secrets secret_store=file"
  @restart_hint "Restart it with `fermix restart`."
  @local_codes [
    :not_running,
    :timeout,
    :invalid_reply,
    :usage,
    :secret_in_argv,
    :app_managed,
    :not_a_terminal,
    :stdin_is_a_terminal,
    :no_input
  ]

  @usage """
  usage: fermix settings [list] [--json]
         fermix settings show SECTION [--info] [--json]
         fermix settings set SECTION KEY=VALUE [KEY=VALUE...] [--json]
         fermix settings secret set ID [--stdin] [--json]
         fermix settings secret clear ID [--json]
         fermix settings primary [PROVIDER] [--json]
         fermix settings reload [--json]
  """

  @type rendered :: {:ok, iodata()} | {:error, :invalid_reply}
  @type context :: %{
          required(:subject) => :read | :change | :secret_set | :secret_clear,
          required(:timeout_ms) => pos_integer(),
          required(:section) => String.t() | nil,
          required(:check) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc "settings.sections as a PANE/SECTION/TITLE table."
  @spec sections(map()) :: rendered()
  def sections(%{"sections" => sections}) when is_list(sections) do
    if Enum.all?(sections, &section_entry?/1),
      do: {:ok, ["PANE\tSECTION\tTITLE\n" | Enum.map(sections, &section_line/1)]},
      else: invalid()
  end

  def sections(_result), do: invalid()

  @doc "The rows of a settings.get result, once its shape is proven."
  @spec rows(map()) :: {:ok, [map()]} | {:error, :invalid_reply}
  def rows(%{"id" => id, "title" => title, "rows" => rows})
      when is_binary(id) and is_binary(title) and is_list(rows) do
    if Enum.all?(rows, &row?/1), do: {:ok, rows}, else: invalid()
  end

  def rows(_result), do: invalid()

  @doc "One section's rows and current values; `info?` adds the info paragraphs."
  @spec section(map(), boolean()) :: rendered()
  def section(view, info?) when is_boolean(info?) do
    with {:ok, rows} <- rows(view) do
      width = rows |> Enum.map(&String.length(safe(&1["key"]))) |> Enum.max(fn -> 0 end)
      header = [safe(view["title"]), "  (", safe(view["id"]), ")\n\n"]
      {:ok, [header | Enum.map(rows, &row_block(&1, width, info?))]}
    end
  end

  @doc "A settings.apply result: saved keys, side effects, restart, readiness."
  @spec applied(map(), String.t(), [String.t()]) :: rendered()
  def applied(
        %{"applied" => applied, "restart" => restart, "readiness" => readiness} = result,
        section,
        sent
      )
      when is_list(applied) and is_binary(section) and is_list(sent) do
    with effects when is_list(effects) <- result["side_effects"],
         true <- strings?(applied) and strings?(effects),
         {:ok, restart_lines} <- restart(restart),
         {:ok, readiness_lines} <- readiness(readiness) do
      saved = ["Saved ", safe(section), ": ", Enum.map_join(applied, ", ", &safe/1), "\n"]

      {:ok,
       [saved, lines(effects), restart_lines, readiness_lines, derived(applied, sent, section)]}
    else
      _invalid -> invalid()
    end
  end

  def applied(_result, _section, _sent), do: invalid()

  @doc "A secret.set or secret.clear result."
  @spec secret(map(), :set | :clear) :: rendered()
  def secret(%{"id" => id, "present" => present, "restart" => restart}, action)
      when is_binary(id) and is_boolean(present) and action in [:set, :clear] do
    with {:ok, restart_lines} <- restart(restart) do
      {:ok, [secret_verb(action), " ", safe(id), ".\n", restart_lines]}
    end
  end

  def secret(_result, _action), do: invalid()

  @doc "setup.state.get's providers as a PROVIDER/NAME/CONFIGURED/PRIMARY table."
  @spec providers(map()) :: rendered()
  def providers(%{"providers" => providers}) when is_list(providers) do
    if Enum.all?(providers, &provider?/1),
      do:
        {:ok, ["PROVIDER\tNAME\tCONFIGURED\tPRIMARY\n" | Enum.map(providers, &provider_line/1)]},
      else: invalid()
  end

  def providers(_result), do: invalid()

  @doc "A providers.set_primary result."
  @spec primary(map(), String.t()) :: rendered()
  def primary(%{"restart" => restart, "side_effects" => effects}, provider)
      when is_list(effects) and is_binary(provider) do
    with true <- strings?(effects),
         {:ok, restart_lines} <- restart(restart) do
      {:ok, ["Primary provider is now ", safe(provider), ".\n", lines(effects), restart_lines]}
    else
      _invalid -> invalid()
    end
  end

  def primary(_result, _provider), do: invalid()

  @doc "A settings.reload result."
  @spec reload(map()) :: rendered()
  def reload(%{"reloaded" => true, "restart" => restart, "readiness" => readiness} = result) do
    with state when is_binary(state) <- result["config_state"],
         {:ok, restart_lines} <- restart(restart),
         {:ok, readiness_lines} <- readiness(readiness) do
      {:ok,
       ["Reloaded settings from disk.\n", restart_lines, readiness_lines, config_state(state)]}
    else
      _invalid -> invalid()
    end
  end

  def reload(_result), do: invalid()

  @doc "A failure as `{exit_code, sentence}`: 3 for no daemon, 1 for every other."
  @spec error(term(), context()) :: {pos_integer(), String.t()}
  def error(:not_running, ctx) when is_map(ctx), do: {3, @not_running}

  def error({:management_error, code, _message, details} = reason, ctx)
      when is_binary(code) and is_map(details) and is_map(ctx),
      do: {1, management(reason, ctx)}

  def error(:timeout, ctx) when is_map(ctx), do: {1, timeout(ctx)}
  def error(:invalid_reply, ctx) when is_map(ctx), do: {1, "invalid daemon reply"}
  def error(:app_managed, ctx) when is_map(ctx), do: {1, HomeOwner.settings_refusal_sentence()}
  def error(reason, ctx) when is_map(ctx), do: {1, local(reason)}

  @doc "The `--json` error object: a management error whole, anything else as a code."
  @spec error_json(term()) :: map()
  def error_json({:management_error, code, message, details}),
    do: %{"error" => %{"code" => code, "message" => message, "details" => details}}

  def error_json(reason), do: %{"error" => %{"code" => local_code(reason)}}

  @doc "One JSON document on one line."
  @spec json(term()) :: String.t()
  def json(term), do: Jason.encode!(term)

  @doc "The usage text, led by why it is shown."
  @spec usage(String.t()) :: String.t()
  def usage(reason) when is_binary(reason), do: "fermix settings: #{scrub(reason)}\n" <> @usage

  @doc "The rotate-it message for a secret typed as an argument."
  @spec secret_in_argv(:set | :secret_set, String.t()) :: String.t()
  def secret_in_argv(:set, key) when is_binary(key) do
    key = safe(key)

    """
    fermix settings set: #{key} is a secret, and a secret is never taken as an argument:
    an argument is visible in `ps` and lands in your shell history. Treat the value you just
    typed as exposed and rotate it. Use one of:

    #{safe_forms(key)}\
    """
  end

  def secret_in_argv(:secret_set, id) when is_binary(id) do
    id = safe(id)

    """
    fermix settings secret set: a secret is never taken as an argument: an argument is
    visible in `ps` and lands in your shell history. Treat the value you just typed as
    exposed and rotate it. Use one of:

    #{safe_forms(id)}\
    """
  end

  defp safe_forms(id) do
    "  fermix settings secret set #{id}  # prompts; input is not echoed\n" <>
      "  ... | fermix settings secret set #{id} --stdin  # reads it from stdin\n"
  end

  defp section_entry?(%{"id" => id, "pane" => pane, "title" => title}),
    do: is_binary(id) and is_binary(pane) and is_binary(title)

  defp section_entry?(_entry), do: false

  defp section_line(entry),
    do: [safe(entry["pane"]), "\t", safe(entry["id"]), "\t", safe(entry["title"]), "\n"]

  defp row?(%{"key" => key, "kind" => kind, "label" => label} = row)
       when is_binary(key) and is_binary(kind) and is_binary(label),
       do: options?(Map.get(row, "options"))

  defp row?(_row), do: false

  defp options?(nil), do: true
  defp options?(options) when is_list(options), do: Enum.all?(options, &option?/1)
  defp options?(_options), do: false

  defp option?(%{"value" => value}), do: is_binary(value)
  defp option?(_option), do: false

  defp row_block(row, width, info?) do
    indent = String.duplicate(" ", width + 4)
    key = String.pad_trailing(safe(row["key"]), width)
    head = ["  ", key, "  ", safe(row["label"]), ": ", value(row), "  [", flags(row), "]\n"]
    [head | Enum.map(details(row, info?), &[indent, &1, "\n"])]
  end

  defp details(row, info?), do: footer(row) ++ info(row, info?) ++ options(row) ++ change(row)

  defp footer(%{"footer" => footer}) when is_binary(footer), do: [safe(footer)]
  defp footer(_row), do: []

  defp info(%{"info" => info}, true) when is_binary(info), do: [paragraph(info)]
  defp info(_row, _info?), do: []

  defp change(%{"kind" => "secret", "key" => key}),
    do: [["change: fermix settings secret set ", safe(key)]]

  defp change(_row), do: []

  defp options(%{"kind" => "choice", "options" => [_ | _] = options} = row) do
    header = if row["suggestions"] == true, do: "suggested:", else: "one of:"
    [header | Enum.map(options, &["  - ", option(&1)])]
  end

  defp options(_row), do: []

  defp option(option) do
    value = safe(option["value"])

    case option_label(option["label"], value) ++ option_hint(option) do
      [] -> value
      notes -> [value, " (", Enum.intersperse(notes, "; "), ")"]
    end
  end

  defp option_label(label, value) when is_binary(label) do
    if safe(label) == value, do: [], else: [safe(label)]
  end

  defp option_label(_label, _value), do: []

  defp option_hint(%{"disabled" => true, "hint" => hint}) when is_binary(hint),
    do: ["unavailable: " <> safe(hint)]

  defp option_hint(%{"disabled" => true}), do: ["unavailable"]
  defp option_hint(%{"hint" => hint}) when is_binary(hint), do: [safe(hint)]
  defp option_hint(_option), do: []

  # A secret row carries no value on the wire; a reply that does carries one
  # this renderer never reads.
  defp value(%{"kind" => "secret", "present" => true}), do: "stored"
  defp value(%{"kind" => "secret"}), do: "not set"

  defp value(%{"kind" => "number", "value" => number} = row) when is_number(number),
    do: number(number, row)

  defp value(row), do: plain(Map.get(row, "value"))

  # Display only: the operator types the raw number.
  defp number(number, %{"format" => "percent"}), do: "#{number} (#{round(number * 100)}%)"
  defp number(number, %{"unit" => unit}) when is_binary(unit), do: "#{number} #{safe(unit)}"

  defp number(number, %{"format" => format}) when format in ["hours", "minutes"],
    do: "#{number} #{format}"

  defp number(number, %{"format" => "currency_cents"}), do: "#{number} cents"

  defp number(number, _row), do: to_string(number)

  defp plain(nil), do: "(not set)"
  defp plain(""), do: "(not set)"
  defp plain([]), do: "(none)"
  defp plain(value) when is_binary(value), do: safe(value)
  defp plain(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp plain(values) when is_list(values), do: values |> Enum.map_join(", ", &item/1) |> safe()
  defp plain(value), do: value |> Jason.encode!() |> safe()

  defp item(value) when is_binary(value), do: value
  defp item(value), do: Jason.encode!(value)

  defp flags(row) do
    [kind_flag(row)]
    |> add_flag(row["restart"] == true, "needs restart")
    |> add_flag(row["read_only"] == true, "shown here, changed elsewhere")
    |> Enum.intersperse(", ")
  end

  defp add_flag(flags, true, flag), do: flags ++ [flag]
  defp add_flag(flags, false, _flag), do: flags

  defp kind_flag(%{"kind" => "choice", "suggestions" => true}), do: "choice (any value)"
  defp kind_flag(%{"kind" => "number"} = row), do: ["number", range(row["min"], row["max"])]
  defp kind_flag(%{"kind" => kind}), do: safe(kind)

  defp range(min, max) when is_number(min) and is_number(max), do: " #{min} to #{max}"
  defp range(min, _max) when is_number(min), do: " >= #{min}"
  defp range(_min, max) when is_number(max), do: " <= #{max}"
  defp range(_min, _max), do: ""

  defp restart(%{"required" => required, "reasons" => reasons})
       when is_boolean(required) and is_list(reasons) do
    if Enum.all?(reasons, &reason?/1),
      do: {:ok, restart_lines(required, reasons)},
      else: invalid()
  end

  defp restart(_restart), do: invalid()

  defp reason?(%{"sentence" => sentence}), do: is_binary(sentence)
  defp reason?(_reason), do: false

  defp restart_lines(false, []), do: []
  defp restart_lines(true, []), do: ["Restart to apply (fermix restart).\n"]

  defp restart_lines(_required, reasons) do
    [
      "Restart to apply (fermix restart):\n"
      | Enum.map(reasons, &["  - ", safe(&1["sentence"]), "\n"])
    ]
  end

  defp readiness(%{"status" => "ready"}), do: {:ok, []}

  defp readiness(%{"status" => status} = readiness) when is_binary(status) do
    failing = failing(readiness["failure_count"])
    {:ok, ["Readiness is ", safe(status), failing, "; `fermix doctor` says why.\n"]}
  end

  defp readiness(_readiness), do: invalid()

  defp failing(count) when is_integer(count), do: " (#{count} failing)"
  defp failing(_count), do: ""

  # The daemon adds keys it derived from the ones sent (the realtime engine and
  # voice follow the model), and those can change which rows the section has.
  defp derived(applied, sent, section) do
    if Enum.all?(applied, &(&1 in sent)),
      do: [],
      else: [
        "(rows in this section changed; run `fermix settings show ",
        safe(section),
        "` to see them)\n"
      ]
  end

  defp config_state("clear"), do: []
  defp config_state(state), do: ["config.toml state: ", safe(state), "\n"]

  defp provider?(%{
         "id" => id,
         "label" => label,
         "configured" => configured,
         "primary" => primary
       }),
       do: is_binary(id) and is_binary(label) and is_boolean(configured) and is_boolean(primary)

  defp provider?(_provider), do: false

  defp provider_line(provider) do
    [
      safe(provider["id"]),
      "\t",
      safe(provider["label"]),
      "\t",
      yes_no(provider["configured"]),
      "\t",
      yes_no(provider["primary"]),
      "\n"
    ]
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"

  defp secret_verb(:set), do: "Stored"
  defp secret_verb(:clear), do: "Cleared"

  defp management({:management_error, "invalid_params", _message, details}, ctx),
    do: invalid_params(details, ctx)

  defp management({:management_error, "external_change", _message, _details}, _ctx),
    do: @external_change

  defp management(
         {:management_error, "config_unreadable", _message, %{"sentence" => sentence}},
         _ctx
       )
       when is_binary(sentence) do
    "config.toml could not be read: #{sentence |> safe() |> String.trim_trailing(".")}. " <>
      "Fix it, then run `fermix settings reload`."
  end

  defp management(
         {:management_error, "secret_store_failed", _message, %{"reason" => reason}},
         _ctx
       )
       when is_binary(reason),
       do: store_failed(reason)

  defp management({:management_error, code, _message, details}, _ctx)
       when code in ["method_not_found", "client_too_old", "daemon_too_old"],
       do: version_skew(code, details)

  defp management({:management_error, _code, _message, %{"sentence" => sentence}}, _ctx)
       when is_binary(sentence),
       do: safe(sentence)

  defp management(reason, _ctx), do: reason |> Client.describe_error() |> safe()

  # The field is printed only when a section is in play, where it names the row
  # the sentence is about; elsewhere it is a request parameter the operator never
  # typed (`provider`, `id`).
  defp invalid_params(%{"sentence" => sentence} = details, ctx) when is_binary(sentence),
    do: field_prefix(details["field"], ctx) <> safe(sentence)

  defp invalid_params(%{"field" => "section"}, %{section: section}) when is_binary(section),
    do: ~s(this daemon has no settings section "#{safe(section)}"; `fermix settings` lists them.)

  defp invalid_params(%{"field" => field}, _ctx) when is_binary(field),
    do: "the daemon refused the request (field #{safe(field)})."

  defp invalid_params(_details, _ctx), do: "the daemon refused the request."

  defp field_prefix(field, %{section: section})
       when is_binary(field) and is_binary(section) and field != section,
       do: safe(field) <> ": "

  defp field_prefix(_field, _ctx), do: ""

  defp store_failed("locked"),
    do:
      "the keyring is locked or refused the write, so nothing was stored.\n" <> @file_store_remedy

  defp store_failed("unavailable"),
    do:
      "no keyring is available to the Fermix service, so nothing was stored.\n" <>
        @file_store_remedy

  defp store_failed("timeout"),
    do:
      "the keyring did not answer within its unlock wait; nothing was stored.\n" <>
        @file_store_remedy

  defp store_failed(reason),
    do: "the secret could not be stored (#{safe(reason)}); nothing was stored."

  defp version_skew("method_not_found", %{"method" => method}) when is_binary(method),
    do:
      "the running daemon is older than this fermix and has no #{safe(method)}.\n" <>
        @restart_hint

  defp version_skew("method_not_found", _details),
    do: "the running daemon is older than this fermix.\n" <> @restart_hint

  defp version_skew("client_too_old", _details) do
    "the running daemon does not speak this fermix's management protocol.\n" <>
      "Restart it with `fermix restart` so both run the same version."
  end

  defp version_skew("daemon_too_old", _details),
    do: "the running daemon is older than this fermix's management protocol.\n" <> @restart_hint

  # A receive timeout is ambiguous: the daemon may still finish the write, so a
  # write never reads as "not saved".
  defp timeout(%{subject: :read, timeout_ms: ms}),
    do: "the daemon did not answer within #{seconds(ms)} s."

  defp timeout(%{subject: :change, timeout_ms: ms, check: check}) when is_binary(check) do
    "the daemon did not answer within #{seconds(ms)} s; the change may still be applied. " <>
      "Check with `#{safe(check)}`."
  end

  defp timeout(%{subject: :secret_set, timeout_ms: ms}) do
    "the daemon did not answer within #{seconds(ms)} s; the secret may still be stored. " <>
      "Check whether its row shows it as stored with `fermix settings show SECTION`."
  end

  defp timeout(%{subject: :secret_clear, timeout_ms: ms}) do
    "the daemon did not answer within #{seconds(ms)} s; the secret may still be cleared. " <>
      "Check its row with `fermix settings show SECTION`."
  end

  defp seconds(ms), do: div(ms, 1_000)

  # SecretInput's error terms never carry the value, so they are safe to name.
  defp local(:not_a_terminal) do
    "reading a secret without echo needs a terminal, and stdin is not one. " <>
      "Pipe the secret in with --stdin instead."
  end

  defp local(:stdin_is_a_terminal) do
    "--stdin was passed but stdin is a terminal. Pipe the secret in, " <>
      "or drop --stdin to be prompted."
  end

  defp local(:no_input), do: "no secret was read, so nothing was stored."

  defp local(reason) do
    if secret_read_failure?(reason),
      do: "the secret could not be read (#{safe(inspect(reason))}); nothing was stored.",
      else: reason |> Client.describe_error() |> safe()
  end

  defp secret_read_failure?(:unexpected_input_encoding), do: true
  defp secret_read_failure?({:terminal_setup_failed, _reason}), do: true
  defp secret_read_failure?({:read_failed, _reason}), do: true
  defp secret_read_failure?(_reason), do: false

  defp local_code(reason) when reason in @local_codes, do: Atom.to_string(reason)

  defp local_code(reason)
       when reason in [:invalid_management_response, :response_request_id_mismatch],
       do: "invalid_reply"

  defp local_code("response_decode_failed:" <> _position), do: "invalid_reply"

  defp local_code(reason) do
    if secret_read_failure?(reason), do: "secret_read_failed", else: "transport_error"
  end

  defp strings?(values), do: Enum.all?(values, &is_binary/1)
  defp lines(values), do: Enum.map(values, &[safe(&1), "\n"])

  defp invalid, do: {:error, :invalid_reply}

  defp safe(value), do: value |> scrub() |> truncate(@field_max)
  defp paragraph(value), do: value |> scrub() |> truncate(@paragraph_max)
  defp scrub(value), do: String.replace(value, @control_chars, " ")

  defp truncate(value, max) do
    if String.length(value) > max, do: String.slice(value, 0, max) <> "…", else: value
  end
end
