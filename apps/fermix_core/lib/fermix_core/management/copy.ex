defmodule FermixCore.Management.Copy do
  @moduledoc """
  The rules every daemon-owned sentence on the management wire obeys
  (M34 native setup §7.7, §7.8 step 4).

  Row labels, footers, choice options, section titles, remediation titles and
  bodies, refusal sentences, restart reasons and the readiness actions are all
  written here in Elixir and rendered verbatim by two front-ends. Neither door
  can correct them, so the rules live beside the strings rather than in a
  reviewer's head, and `copy_test.exs` walks the live producers rather than a
  hand-listed sample.

  The rules, and what each one is for:

    * `:em_dash` — an em or en dash. The product's copy uses a full stop or a
      colon, and a dash reads as a different voice inside one window.
    * `:exclamation` — an exclamation mark. Setup copy states facts.
    * `:mix_task` — a Mix task name (`mix fermix.setup`). An installed operator
      has no `mix`, so naming one is advice they cannot follow.
    * `:version_number` — a dotted version. Copy that names a version is stale
      the moment the next one ships; prose only, because a model or voice name
      is a catalog identity this daemon reflects rather than copy it wrote.
    * `:wire_token` — a bare `snake_case` or `UPPER_SNAKE` identifier outside
      backticks. A configuration key, an internal atom or an environment
      variable rendered as prose reads as a typo to everyone who has not read
      the source; backtick it and it is a literal the operator can type.
    * `:sentence_case` — a capitalised word that neither starts a sentence, nor
      is an initialism, nor is a proper noun. Prose only: a label, a section
      title and a choice option are names, not sentences.

  `:prose` runs every rule; `:name` runs the four that apply to a name. A
  proper noun the daemon interpolates rather than writes (a plugin's display
  name, an account label) is passed in as `names` at the call site, because the
  rule set cannot know it and a list of every vendor on earth would rot. A
  declared name is data, so no rule reads it: the sandbox row labelled with the
  environment variable an operator allowed is `UPPER_SNAKE` by convention, and
  it is the operator's word rather than one this daemon wrote.

  The words of `home.status.summary` (M75 lean v1 §7) are held here too, beside
  the rules (`summary_sentence/2`, `summary_label/2`): one
  sentence and at most one action for where Always On stands, which the Mac
  app, the Linux app, the setup page and `fermix home status` print as they
  are (`FermixCore.Management.HomeSummary` picks them). They obey one rule
  more, `summary_violations/1`: none of the engine's own words for the move
  or itself (epoch, primary, candidate, relay, rail, phase, ledger, daemon,
  key id) reaches an owner (`internal_words/1`), and no backticked literal,
  code or secret id does either. A cloud provider's words (its name, its
  token's label, its cities, its "How to get one" steps) are its own display
  data (`FermixCore.Home.Provision`), passed in as values; the proper nouns
  they use are read from the provider registry.

  Beside them sit the rest of what an Always On screen shows (Always On
  setup §3.1): the sentence each action's confirm asks (`summary_sentence/2`'s
  `confirm_*` keys, and `move_confirm/1` for Move now, built from the
  review's own warnings), never with a time or a price in it; the sentence
  of the step a job is in (`progress_*`); a notice's sentence (`notice_*`);
  the Details lines (`summary_line/3`), each a label and a value finished
  here, times stated absolutely in the owner's zone (`FermixCore.Clock`),
  prices as the ledger keeps them; the Always On docs page
  (`always_on_docs_url/1`); and the command for a server of the owner's own
  (`own_server_command/0`), which carries no code.
  """

  alias FermixCore.Clock
  alias FermixCore.Home.Disk
  alias FermixCore.Home.Provision.Registry, as: ProvisionRegistry
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Setup.SecretPaths

  @type kind :: :prose | :name
  @type violation :: {atom(), String.t()}

  @em_dashes ["—", "–"]
  @backticked ~r/`[^`]*`/
  @backtick_or_span ~r/`[^`]*`|`/
  @cue_secret_id ~r/\bcue_source:[A-Za-z0-9_-]+:[a-z_]+/
  @mix_task ~r/\bmix\s+[a-z][a-z0-9_]*\.[a-z]/
  @version ~r/\bv?\d+\.\d+(?:\.\d+)?\b/
  @wire_token ~r/\b(?:[a-z][a-z0-9]*(?:_[a-z0-9]+)+|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\b/
  @capitalised ~r/\b[A-Z][a-z]+\b/
  # The engine's own words for the move, and for itself, which no summary
  # word may carry. A key id is the recovery key's; an S3 "access key ID" is
  # AWS's name.
  @internal_words ~r/\b(?:epochs?|primar(?:y|ies)|candidates?|relays?|rails?|phases?|ledgers?|daemons?|(?<!access )key ids?)\b/i
  # What runs only on the computer a move leaves, in the order it is named.
  @stays_here [imessage: "iMessage", voice: "voice calls", meetings: "meetings"]
  @summary_keys ~w(off connect choose starting installing connecting deleting ready moving
                   waiting on on_backup on_no_backup undone retired candidate_waiting
                   candidate_receiving primary turned_off cannot_reach deleted not_set_up
                   server_not_set_up waited_too_long server_waited_too_long token_refused
                   update disk_full server_disk_full backup_old backup_none server_backup_old
                   backup_push not_ready turned_off_cost server_costs billing data
                   replace_creating replace_starting replace_installing replace_connecting
                   replace_ready replace_moving replace_deleting replace_cancelling
                   replace_turned_off replace_not_set_up replace_waited_too_long
                   new_server_costs old_server_costs turning_on replace_turning_on restarting
                   progress_checking progress_firewall progress_server progress_starting
                   progress_deleting progress_power confirm_create confirm_create_in
                   confirm_start_again confirm_replace confirm_restart confirm_delete
                   confirm_cancel confirm_replace_move notice_ready notice_moved
                   notice_backup_week notice_server_backup_week)a
  # Each Details line's label, by its key.
  @line_labels [
    server: "Server",
    size: "Size",
    place: "Place",
    address: "Address",
    system: "System",
    version: "Version",
    waits_until: "Waits until",
    checked: "Last checked",
    costs: "Costs",
    old_costs: "Old server costs",
    disk: "Server disk"
  ]
  @line_keys Keyword.keys(@line_labels) ++ [:backup, :copies]
  @docs_url "https://fermix.ai/docs/always-on/"
  @own_server_command "curl -fsSL https://fermix.ai/always-on | sudo sh"
  @currency_signs %{"EUR" => "€", "USD" => "$", "GBP" => "£"}
  # A sentence starts at the beginning of the string and after a terminator or
  # a colon, which is how this copy introduces a command or a list.
  @sentence_break ~r/(?<=[.?:])\s+/

  # The hand-maintained half, and the only one. Every entry is asserted used by
  # a live string, so a name that leaves the copy leaves this list in the same
  # change. Provider labels, and the names a cloud provider's own words use,
  # are derived below rather than repeated here.
  @proper_nouns [
    "Fermix Computer Use",
    "Fermix Messages",
    "Always On",
    # The system of the server Always On moves to, and the one Fermix creates
    # its server with.
    "Linux",
    "Debian",
    "Apple ID",
    "Apple",
    "Full Disk Access",
    "Automation",
    "Messages",
    "Claude Code",
    "New York",
    "Los Angeles",
    "Sao Paulo",
    "Fermix",
    "Mac",
    "Doctor",
    "Claude",
    "Codex",
    "Grok",
    "Realtime",
    "Providers",
    "Channels",
    "Plugins",
    "Cues",
    # The Cues screen's option, named as the settings label it.
    "Keyword match",
    "Voice",
    "Telegram",
    "WhatsApp",
    "Discord",
    "Slack",
    "Socket Mode",
    "Signal",
    "Google Meet",
    "Zoom",
    "Personality",
    "Tailscale",
    "Google Chrome for Testing",
    "Google Chrome Canary",
    "Google Chrome",
    "Chromium",
    "Chrome",
    "Google",
    "Android",
    "Node.js",
    "Atom",
    # GitHub's webhook form, named as GitHub labels it.
    "Add webhook",
    "Payload URL",
    "Webhooks",
    "Settings"
  ]

  @doc """
  Every rule this contract enforces, ordered, so a gate can name them.
  """
  @spec rules() :: [atom()]
  def rules, do: [:em_dash, :exclamation, :mix_task, :version_number, :wire_token, :sentence_case]

  @doc """
  The proper nouns and proper phrases the sentence-case rule accepts.

  Provider labels are read from the descriptor registry, and the names each
  Always On cloud provider's words use from its display data, so a provider
  added in Elixir needs no entry here; the rest is the hand-maintained list
  this module documents.
  """
  @spec proper_nouns() :: [String.t()]
  def proper_nouns do
    (@proper_nouns ++ descriptor_names() ++ provision_names())
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
  end

  @doc """
  Every rule `text` breaks, as `{rule, the offending fragment}`.

  `names` carries names this string interpolates rather than writes, so a
  plugin's display name inside a daemon sentence, or the variable name a row is
  labelled with, is data rather than a defect.
  """
  @spec violations(String.t(), kind(), [String.t()]) :: [violation()]
  def violations(text, kind, names \\ [])
      when is_binary(text) and kind in [:prose, :name] and is_list(names) do
    literal = @backticked |> Regex.replace(text, "``") |> strip_names(names)

    Enum.concat([
      dash_violations(text),
      bang_violations(text),
      pattern_violations(@mix_task, literal, :mix_task),
      prose_only(kind, fn -> pattern_violations(@version, literal, :version_number) end),
      token_violations(literal),
      prose_only(kind, fn -> case_violations(literal, names) end)
    ])
  end

  defp prose_only(:prose, run), do: run.()
  defp prose_only(:name, _run), do: []

  defp dash_violations(text) do
    for dash <- @em_dashes, String.contains?(text, dash), do: {:em_dash, dash}
  end

  defp bang_violations(text) do
    if String.contains?(text, "!"), do: [{:exclamation, "!"}], else: []
  end

  defp pattern_violations(pattern, text, rule) do
    pattern |> Regex.scan(text) |> Enum.map(fn [match | _rest] -> {rule, match} end)
  end

  defp token_violations(text), do: pattern_violations(@wire_token, text, :wire_token)

  defp case_violations(text, names) do
    stripped = strip_names(text, proper_nouns() ++ names)

    stripped
    |> String.split(@sentence_break)
    |> Enum.flat_map(&offending_words/1)
  end

  # The first word of a sentence is capitalised by construction, so only what
  # follows it can be a defect.
  defp offending_words(sentence) do
    case String.split(sentence, ~r/\s+/, parts: 2) do
      [_first] -> []
      [_first, rest] -> @capitalised |> Regex.scan(rest) |> Enum.map(&{:sentence_case, hd(&1)})
    end
  end

  # Longest first, so "Fermix Computer Use" is removed before "Fermix" can
  # leave "Computer Use" behind as two unexplained capitals.
  defp strip_names(text, names) do
    names
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.reduce(text, &String.replace(&2, &1, "-"))
  end

  # -- the Always On summary's words (M75 lean v1 §7) ---------------------------

  @doc """
  The internal words `text` carries (`@internal_words`, any case): the
  engine's own words for the move, which no summary word may name.
  """
  @spec internal_words(String.t()) :: [String.t()]
  def internal_words(text) when is_binary(text),
    do: @internal_words |> Regex.scan(text) |> Enum.map(&hd/1)

  @doc """
  What keeps `text` from being a summary word beside `violations/3`: each
  internal word (`internal_words/1`), each backticked span or stray backtick,
  and each secret's id (the one `secret.set` takes: `anthropic_api_key`,
  `cue_source:<ref>:<field>`). A summary sentence is plain words an owner
  reads, so it carries no literal to type and no code, which `violations/3`
  lets stand in backticks, and names a secret by what the settings call it
  (`Management.Settings.secret_names/1`), which `violations/3` lets a call
  site declare as data.
  """
  @spec summary_violations(String.t()) :: [violation()]
  def summary_violations(text) when is_binary(text) do
    Enum.map(internal_words(text), &{:internal_word, &1}) ++
      (@backtick_or_span |> Regex.scan(text) |> Enum.map(&{:backtick, hd(&1)})) ++
      secret_ids(text)
  end

  defp secret_ids(text) do
    registry =
      for %{key: key} <- SecretPaths.all(), id = Atom.to_string(key), word?(text, id), do: id

    cues = @cue_secret_id |> Regex.scan(text) |> Enum.map(&hd/1)

    Enum.map(registry ++ cues, &{:secret_id, &1})
  end

  defp word?(text, word), do: Regex.match?(~r/\b#{Regex.escape(word)}\b/, text)

  @doc "Every key `summary_sentence/2` takes, so the copy gate walks them all."
  @spec summary_keys() :: [atom()]
  def summary_keys, do: @summary_keys

  @doc """
  One sentence of `home.status.summary`, by its key, with the values it
  names: `machine` ("Mac" or "computer"), `age` (seconds since the last
  backup), `days`, `percent`, `block` (a readiness sentence), `provider` (a
  cloud provider's name, or who hosts the server), `token_label` (the
  provider's token, as its field is labelled) or `stays_here` (what this home
  uses that stops after a move, `off`'s second line only when there is
  something).
  """
  @spec summary_sentence(atom(), map()) :: String.t()
  def summary_sentence(:off, %{machine: machine, stays_here: features}),
    do:
      "Keep Fermix running when this #{machine} sleeps. It moves to a server you own." <>
        stops_line(features)

  def summary_sentence(:connect, %{token_label: label}),
    do: "Paste a #{label} to let Fermix create your server."

  def summary_sentence(:choose, %{provider: provider}),
    do: "Your #{provider} token works, so choose the server Fermix creates."

  def summary_sentence(:starting, _values), do: "Starting your server…"
  def summary_sentence(:installing, _values), do: "Installing Fermix on your server…"
  def summary_sentence(:connecting, _values), do: "Connecting your server…"
  def summary_sentence(:deleting, _values), do: "Deleting your server…"

  def summary_sentence(:ready, %{machine: machine}),
    do:
      "Your server is ready for the move. There is no way back to this #{machine} in this " <>
        "version."

  def summary_sentence(:moving, %{machine: machine}),
    do:
      "Moving. This #{machine} restarts and reconnects to your server. Messages wait until " <>
        "it is done."

  def summary_sentence(:waiting, _values),
    do: "Waiting for your server to confirm the move. Fermix keeps trying."

  def summary_sentence(:on, _values), do: "Fermix runs on your server."

  def summary_sentence(:on_backup, %{age: age}),
    do: "Fermix runs on your server. Last backup #{ago(age)}."

  def summary_sentence(:on_no_backup, _values),
    do: "Fermix runs on your server. No backup has finished yet."

  def summary_sentence(:undone, %{machine: machine}),
    do: "The move was undone. Fermix still runs on this #{machine}."

  def summary_sentence(:retired, %{machine: machine}),
    do: "Fermix moved to your server, and this #{machine} is no longer connected to it."

  def summary_sentence(:candidate_waiting, _values), do: "This server is waiting for its move."
  def summary_sentence(:candidate_receiving, _values), do: "Your home is moving to this server."
  def summary_sentence(:primary, _values), do: "Fermix runs here."
  def summary_sentence(:turned_off, _values), do: "Your server is turned off."

  def summary_sentence(:cannot_reach, _values),
    do: "Fermix cannot reach your server. Your messages wait until it is back."

  def summary_sentence(:deleted, %{provider: provider}),
    do: "Your server was deleted in #{provider}."

  def summary_sentence(:not_set_up, _values), do: "Your server did not finish setting up."
  def summary_sentence(:server_not_set_up, _values), do: "This server did not finish setting up."

  def summary_sentence(:waited_too_long, _values),
    do: "Your server waited too long and must be set up again."

  def summary_sentence(:server_waited_too_long, _values),
    do: "This server waited too long for its move and must be set up again."

  def summary_sentence(:token_refused, %{provider: provider}),
    do: "#{provider} no longer accepts Fermix's token."

  def summary_sentence(:update, %{machine: machine}),
    do: "Update Fermix on this #{machine} to keep using Always On."

  def summary_sentence(:disk_full, %{percent: percent}),
    do: "Your server's disk is #{percent}% full."

  def summary_sentence(:server_disk_full, %{percent: percent}),
    do: "This server's disk is #{percent}% full."

  def summary_sentence(:backup_old, %{days: days, machine: machine}),
    do: "Your last backup is #{days} days old. It runs when this #{machine} is online."

  def summary_sentence(:backup_none, %{days: days, machine: machine}),
    do:
      "No backup has finished since the move #{days} days ago. It runs when this " <>
        "#{machine} is online."

  def summary_sentence(:server_backup_old, %{days: days}),
    do: "The last backup is #{days} days old. It runs when your Mac is online."

  def summary_sentence(:backup_push, %{days: days}),
    do:
      "Your last backup is #{days} days old. It runs when your Mac is online: open Fermix " <>
        "on your Mac to back up now."

  def summary_sentence(:not_ready, %{block: block}), do: "The move cannot start yet. #{block}"

  def summary_sentence(:turned_off_cost, _values),
    do: "A turned-off server still costs its monthly price."

  def summary_sentence(:server_costs, _values),
    do: "Your server costs its monthly price until it is deleted."

  def summary_sentence(:billing, %{provider: provider}),
    do: "#{provider} bills by the hour until the server is deleted."

  def summary_sentence(:replace_creating, _values), do: "Creating your new server…"
  def summary_sentence(:replace_starting, _values), do: "Starting your new server…"
  def summary_sentence(:replace_installing, _values), do: "Installing Fermix on your new server…"
  def summary_sentence(:replace_connecting, _values), do: "Connecting your new server…"
  def summary_sentence(:replace_ready, _values), do: "Your new server is ready for the move."

  def summary_sentence(:replace_moving, _values),
    do: "Moving to your new server. Messages wait until it is done."

  def summary_sentence(:replace_deleting, _values), do: "Removing your old server…"
  def summary_sentence(:replace_cancelling, _values), do: "Deleting your new server…"
  def summary_sentence(:replace_turned_off, _values), do: "Your new server is turned off."

  def summary_sentence(:replace_not_set_up, _values),
    do: "Your new server did not finish setting up."

  def summary_sentence(:replace_waited_too_long, _values),
    do: "Your new server waited too long and must be set up again."

  def summary_sentence(:new_server_costs, _values),
    do: "Your new server costs its monthly price until it is deleted."

  def summary_sentence(:old_server_costs, _values),
    do: "Your old server costs its monthly price until it is deleted."

  def summary_sentence(:turning_on, _values), do: "Turning your server on…"
  def summary_sentence(:replace_turning_on, _values), do: "Turning your new server on…"
  def summary_sentence(:restarting, _values), do: "Restarting your server…"

  def summary_sentence(:progress_checking, %{provider: provider}),
    do: "Checking that #{provider} has the server in stock."

  def summary_sentence(:progress_firewall, _values), do: "Creating the server's firewall."
  def summary_sentence(:progress_server, _values), do: "Creating the server."
  def summary_sentence(:progress_starting, _values), do: "Waiting for the server to start."

  def summary_sentence(:progress_deleting, _values),
    do: "Deleting the server and what came with it."

  def summary_sentence(:progress_power, %{provider: provider}),
    do: "Waiting for #{provider} to finish."

  def summary_sentence(:confirm_create, %{provider: provider}),
    do: "Create your server? #{provider} bills it by the hour until it is deleted."

  def summary_sentence(:confirm_create_in, %{provider: provider, city: city}),
    do: "Create your server in #{city}? #{provider} bills it by the hour until it is deleted."

  def summary_sentence(:confirm_start_again, %{provider: provider}),
    do:
      "Delete what Fermix created and create your server again? #{provider} bills it by " <>
        "the hour until it is deleted."

  def summary_sentence(:confirm_replace, %{provider: provider}),
    do:
      "Create a new server to replace this one? #{provider} bills it by the hour until it " <>
        "is deleted, and Fermix deletes the old one once the move to it is done."

  def summary_sentence(:confirm_restart, _values),
    do: "Restart your server? Fermix on it stops until it starts again."

  def summary_sentence(:confirm_delete, %{which: which}) when which in ["new", "old"],
    do: "Delete your #{which} server? Everything on it is deleted."

  def summary_sentence(:confirm_delete, _values),
    do: "Delete your server? Everything on it is deleted."

  def summary_sentence(:confirm_cancel, %{which: "new"}),
    do: "Cancel and delete your new server? Everything Fermix created for it is deleted."

  def summary_sentence(:confirm_cancel, _values),
    do: "Cancel and delete your server? Everything Fermix created for it is deleted."

  def summary_sentence(:confirm_replace_move, _values),
    do:
      "Move Fermix to your new server now? Your old server serves nothing while the move " <>
        "runs, and Fermix deletes it once the move is done."

  def summary_sentence(:notice_ready, _values), do: "Your server is ready for the move."
  def summary_sentence(:notice_moved, _values), do: "Fermix moved to your server."

  def summary_sentence(:notice_backup_week, %{machine: machine}),
    do: "Your last backup is a week old. It runs when this #{machine} is online."

  def summary_sentence(:notice_server_backup_week, _values),
    do: "The last backup is a week old. It runs when your Mac is online."

  def summary_sentence(:data, %{provider: provider}),
    do:
      "Your conversations and memories, the secrets, the browser and traces live on your " <>
        "server, and #{provider} can technically read its disk. Backups are encrypted to " <>
        "your recovery passphrase."

  @doc """
  What a move stops among `features` (`:imessage`, `:voice`, `:meetings`),
  as a sentence starts: "iMessage, voice calls and meetings stop after the
  move", "Voice calls stop after the move".
  """
  @spec stops_after_move([:imessage | :voice | :meetings, ...]) :: String.t()
  def stops_after_move([_ | _] = features) do
    names = for {feature, name} <- @stays_here, feature in features, do: name
    true = length(names) == length(Enum.uniq(features))
    verb = if features == [:imessage], do: "stops", else: "stop"

    "#{names |> join_names() |> capitalised()} #{verb} after the move"
  end

  defp stops_line([]), do: ""
  defp stops_line(features), do: " #{stops_after_move(features)}."

  defp join_names([name]), do: name
  defp join_names(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  # A sentence's first letter, unless the first word is iMessage.
  defp capitalised("iMessage" <> _rest = text), do: text
  defp capitalised(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  @doc """
  Move now's confirm: the question, then each warning of the review in its
  own words (`warnings`, the sentences, in the review's order).
  """
  @spec move_confirm([String.t()]) :: String.t()
  def move_confirm(warnings) when is_list(warnings),
    do: Enum.join(["Move Fermix to your server now?" | warnings], " ")

  @doc "Every key `summary_line/3` takes."
  @spec summary_line_keys() :: [atom()]
  def summary_line_keys, do: @line_keys

  @doc "The label of the Details line `key` (`summary_line_keys/0`)."
  @spec summary_line_label(atom()) :: String.t()
  def summary_line_label(:backup), do: "Last backup to your desktop"
  def summary_line_label(:copies), do: "Backups on this Mac"
  def summary_line_label(key), do: Keyword.fetch!(@line_labels, key)

  @doc "The label of the line that says when the provider was last read back."
  @spec checked_label() :: String.t()
  def checked_label, do: summary_line_label(:checked)

  @doc """
  One Details line, `%{"label", "value"}`, its value finished here from
  `value`: a name, a city, an address, a system or a version as it is; a
  time (`waits_until`, `checked`, a `backup`'s `{place, at}`) stated in
  `ctx`'s `zone`; the space this computer's `copies` take, in bytes, on
  `ctx`'s `machine`; how full the server's `disk` is, a fraction; what the
  server (`costs`) or the old one (`old_costs`) costs, `{total_monthly,
  currency}` as the ledger keeps them.
  """
  @spec summary_line(atom(), term(), map()) :: %{String.t() => String.t()}
  def summary_line(:backup, {place, %DateTime{} = at}, %{zone: zone}),
    do: line("Last backup to #{place}", stated(at, zone))

  def summary_line(:copies, bytes, %{machine: machine}) when is_integer(bytes),
    do: line("Backups on this #{machine}", Disk.gib(bytes))

  def summary_line(:disk, used, _ctx) when is_number(used),
    do: line(summary_line_label(:disk), "#{round(used * 100)}% used")

  def summary_line(key, %DateTime{} = at, %{zone: zone}) when key in [:waits_until, :checked],
    do: line(summary_line_label(key), stated(at, zone))

  def summary_line(key, {total, currency}, _ctx) when key in [:costs, :old_costs],
    do: line(summary_line_label(key), offer_price(total, currency))

  def summary_line(key, value, _ctx)
      when key in [:server, :size, :place, :address, :system, :version] and is_binary(value),
      do: line(summary_line_label(key), value)

  defp line(label, value), do: %{"label" => label, "value" => value}

  @doc """
  One offer's size, as `home.provision.options` answers it: the type's name,
  then its cores (dedicated where they are), memory and disk ("CPX22: 2
  cores, 4 GB memory, 80 GB disk").
  """
  @spec offer_label(map()) :: String.t()
  def offer_label(%{
        "description" => name,
        "cores" => cores,
        "memory_gb" => memory,
        "disk_gb" => disk,
        "dedicated" => dedicated
      })
      when is_binary(name) and is_integer(cores) and cores > 0 and is_number(memory) and
             is_integer(disk) and is_boolean(dedicated),
      do: "#{name}: #{cores} #{cores(cores, dedicated)}, #{gb(memory)} GB memory, #{disk} GB disk"

  @doc "One offer's price, `total` a month in `currency`, worded as the Costs line is."
  @spec offer_price(String.t(), String.t()) :: String.t()
  def offer_price(total, currency) when is_binary(total) and is_binary(currency),
    do: "#{money(total, currency)} a month, billed by the hour until deleted"

  defp cores(count, true), do: "dedicated " <> cores(count, false)
  defp cores(1, false), do: "core"
  defp cores(_count, false), do: "cores"

  # A size as a person reads it: 4.0 is 4, 4.5 stays 4.5.
  defp gb(size) when is_integer(size), do: Integer.to_string(size)
  defp gb(size) when size == trunc(size), do: size |> trunc() |> Integer.to_string()
  defp gb(size), do: Float.to_string(size)

  defp stated(at, zone), do: Clock.stated_instant(at, personalization: [timezone: zone])

  # A price as the ledger keeps it ("8.33"), after its currency's sign or code.
  defp money(total, currency) do
    case Map.fetch(@currency_signs, currency) do
      {:ok, sign} -> sign <> total
      :error -> "#{currency} #{total}"
    end
  end

  @doc "The Always On docs page, at the provider's own part (`docs_anchor`)."
  @spec always_on_docs_url(String.t()) :: String.t()
  def always_on_docs_url(anchor) when is_binary(anchor) and anchor != "",
    do: @docs_url <> "#" <> anchor

  @doc """
  The command an owner runs on a Linux server of their own to install Fermix
  there: it carries no code, which the server's first boot asks for on the
  terminal without echo, so the code never lands in its shell history.
  """
  @spec own_server_command() :: String.t()
  def own_server_command, do: @own_server_command

  @doc """
  The label of one summary action, by its id; `create_in` names a `city`,
  `open_console` the `provider`, `delete_server` the server a replace
  deletes (`which`: `"new"` or `"old"`) when there are two, `paste_token` is
  `Set up` on the first token screen (`first`), and `cancel` closes an open
  code (`code`).
  """
  @spec summary_label(atom(), map()) :: String.t()
  def summary_label(:create_server, _values), do: "Create server"
  def summary_label(:cancel, %{code: true}), do: "Cancel the code"
  def summary_label(:cancel, _values), do: "Cancel"
  def summary_label(:move_now, _values), do: "Move now"
  def summary_label(:try_again, _values), do: "Try again"
  def summary_label(:learn_more, _values), do: "Learn more"
  def summary_label(:turn_on, _values), do: "Turn it on"
  def summary_label(:restart_server, _values), do: "Restart server"
  def summary_label(:start_again, _values), do: "Start again"
  def summary_label(:create_in, %{city: city}), do: "Create in #{city}"
  def summary_label(:open_console, %{provider: provider}), do: "Open #{provider}"
  def summary_label(:paste_token, %{first: true}), do: "Set up"
  def summary_label(:paste_token, _values), do: "Paste a new token"
  def summary_label(:update, _values), do: "Update"
  def summary_label(:back_up_now, _values), do: "Back up now"
  def summary_label(:replace_server, _values), do: "Replace the server"
  def summary_label(:check_again, _values), do: "Check again"
  def summary_label(:own_server, _values), do: "Use my own Linux server"

  def summary_label(:delete_server, %{which: which}) when which in ["new", "old"],
    do: "Delete your #{which} server"

  def summary_label(:delete_server, _values), do: "Delete your server"

  # How long ago, in the largest whole unit: minutes, hours or days.
  defp ago(seconds) when seconds < 60, do: "just now"
  defp ago(seconds) when seconds < 3_600, do: count(div(seconds, 60), "minute") <> " ago"
  defp ago(seconds) when seconds < 86_400, do: count(div(seconds, 3_600), "hour") <> " ago"
  defp ago(seconds), do: count(div(seconds, 86_400), "day") <> " ago"

  defp count(1, unit), do: "1 #{unit}"
  defp count(n, unit), do: "#{n} #{unit}s"

  defp provision_names, do: Enum.flat_map(ProvisionRegistry.all(), & &1.display().proper_nouns)

  defp descriptor_names do
    Descriptor.all()
    |> Enum.flat_map(&String.split(&1.label, ~r/[\s()]+/, trim: true))
    |> Enum.filter(&Regex.match?(~r/^[A-Z]/, &1))
  end
end
