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
  the rules (`summary_sentence/2`, `summary_label/2`, `token_steps/0`): one
  sentence and at most one action for where Always On stands, which the Mac
  app, the Linux app, the setup page and `fermix home status` print as they
  are (`FermixCore.Management.HomeSummary` picks them). They obey one rule
  more, `summary_violations/1`: none of the engine's own words for the move
  (epoch, primary, candidate, relay, rail, phase, ledger, key id) reaches an
  owner (`internal_words/1`), and no backticked literal or code does either.
  """

  alias FermixCore.Providers.Descriptor

  @type kind :: :prose | :name
  @type violation :: {atom(), String.t()}

  @em_dashes ["—", "–"]
  @backticked ~r/`[^`]*`/
  @backtick_or_span ~r/`[^`]*`|`/
  @mix_task ~r/\bmix\s+[a-z][a-z0-9_]*\.[a-z]/
  @version ~r/\bv?\d+\.\d+(?:\.\d+)?\b/
  @wire_token ~r/\b(?:[a-z][a-z0-9]*(?:_[a-z0-9]+)+|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\b/
  @capitalised ~r/\b[A-Z][a-z]+\b/
  # The engine's own words for the move, which no summary word may carry.
  @internal_words ~r/\b(?:epochs?|primar(?:y|ies)|candidates?|relays?|rails?|phases?|ledgers?|key ids?)\b/i
  @cities %{"fsn1" => "Falkenstein", "nbg1" => "Nuremberg", "hel1" => "Helsinki"}
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
                   new_server_costs old_server_costs)a
  # A sentence starts at the beginning of the string and after a terminator or
  # a colon, which is how this copy introduces a command or a list.
  @sentence_break ~r/(?<=[.?:])\s+/

  # The hand-maintained half, and the only one. Every entry is asserted used by
  # a live string, so a name that leaves the copy leaves this list in the same
  # change. Provider labels are derived below rather than repeated here.
  @proper_nouns [
    "Fermix Computer Use",
    "Fermix Messages",
    "Always On",
    # The Always On host, the permission its API token needs, as Hetzner names
    # it, the three locations Fermix creates a server in, and its system.
    "Read & Write",
    "Hetzner",
    "Debian",
    "Linux",
    "Falkenstein",
    "Nuremberg",
    "Helsinki",
    # The two places in Hetzner's console the token steps name, as it labels
    # them.
    "API Tokens",
    "Security",
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

  Provider labels are read from the descriptor registry, so a provider added in
  Elixir needs no entry here; the rest is the hand-maintained list this module
  documents.
  """
  @spec proper_nouns() :: [String.t()]
  def proper_nouns do
    (@proper_nouns ++ descriptor_names())
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
  internal word (`internal_words/1`) and each backticked span or stray
  backtick. A summary sentence is plain words an owner reads, so it carries no
  literal to type and no code, which `violations/3` lets stand in backticks.
  """
  @spec summary_violations(String.t()) :: [violation()]
  def summary_violations(text) when is_binary(text) do
    Enum.map(internal_words(text), &{:internal_word, &1}) ++
      (@backtick_or_span |> Regex.scan(text) |> Enum.map(&{:backtick, hd(&1)}))
  end

  @doc "Every key `summary_sentence/2` takes, so the copy gate walks them all."
  @spec summary_keys() :: [atom()]
  def summary_keys, do: @summary_keys

  @doc """
  One sentence of `home.status.summary`, by its key, with the values it
  names: `machine` ("Mac" or "computer"), `age` (seconds since the last
  backup), `days`, `percent`, `block` (a readiness sentence), `provider` or
  `stays_here` (what this home uses that stops after a move, `off`'s second
  line only when there is something).
  """
  @spec summary_sentence(atom(), map()) :: String.t()
  def summary_sentence(:off, %{machine: machine, stays_here: features}),
    do:
      "Keep Fermix running when this #{machine} sleeps. It moves to a server you own." <>
        stops_line(features)

  def summary_sentence(:connect, _values),
    do: "Paste a Hetzner API token to let Fermix create your server."

  def summary_sentence(:choose, _values),
    do: "Your Hetzner token works, so choose the server Fermix creates."

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

  def summary_sentence(:deleted, _values), do: "Your server was deleted in Hetzner."
  def summary_sentence(:not_set_up, _values), do: "Your server did not finish setting up."
  def summary_sentence(:server_not_set_up, _values), do: "This server did not finish setting up."

  def summary_sentence(:waited_too_long, _values),
    do: "Your server waited too long and must be set up again."

  def summary_sentence(:server_waited_too_long, _values),
    do: "This server waited too long for its move and must be set up again."

  def summary_sentence(:token_refused, _values), do: "Hetzner no longer accepts Fermix's token."

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

  def summary_sentence(:billing, _values),
    do: "Hetzner bills by the hour until the server is deleted."

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
  The label of one summary action, by its id; `create_in` names the city of
  `location` (`fsn1`, `nbg1` or `hel1`), and `delete_server` the server a
  replace deletes (`which`: `"new"` or `"old"`) when there are two.
  """
  @spec summary_label(atom(), map()) :: String.t()
  def summary_label(:set_up, _values), do: "Set up"
  def summary_label(:create_server, _values), do: "Create server"
  def summary_label(:cancel, _values), do: "Cancel"
  def summary_label(:move_now, _values), do: "Move now"
  def summary_label(:try_again, _values), do: "Try again"
  def summary_label(:learn_more, _values), do: "Learn more"
  def summary_label(:turn_on, _values), do: "Turn it on"
  def summary_label(:restart_server, _values), do: "Restart server"
  def summary_label(:start_again, _values), do: "Start again"
  def summary_label(:create_in, %{location: location}), do: "Create in #{city(location)}"
  def summary_label(:open_hetzner, _values), do: "Open Hetzner"
  def summary_label(:paste_token, _values), do: "Paste a new token"
  def summary_label(:update, _values), do: "Update"
  def summary_label(:back_up_now, _values), do: "Back up now"
  def summary_label(:replace_server, _values), do: "Replace the server"
  def summary_label(:check_again, _values), do: "Check again"
  def summary_label(:own_server, _values), do: "Use my own Linux server"

  def summary_label(:delete_server, %{which: which}) when which in ["new", "old"],
    do: "Delete your #{which} server"

  def summary_label(:delete_server, _values), do: "Delete your server"

  @doc """
  The "How to get one" steps of the token screen (M75 lean v1 §2, L20): two-
  factor sign-in first, and a project made for Fermix alone, since a token
  reaches its whole project.
  """
  @spec token_steps() :: [String.t()]
  def token_steps do
    [
      "Sign in to Hetzner's console and turn on two-factor sign-in for your account.",
      "Make a new project for Fermix alone, so the token reaches nothing else.",
      "In that project, open Security, then API Tokens, and generate a token with Read & " <>
        "Write permission.",
      "Paste the token here: Fermix checks it at once."
    ]
  end

  @doc "The city of a Hetzner location Fermix creates a server in, as Hetzner names it."
  @spec city(String.t()) :: String.t()
  def city(location) when is_map_key(@cities, location), do: Map.fetch!(@cities, location)

  # How long ago, in the largest whole unit: minutes, hours or days.
  defp ago(seconds) when seconds < 60, do: "just now"
  defp ago(seconds) when seconds < 3_600, do: count(div(seconds, 60), "minute") <> " ago"
  defp ago(seconds) when seconds < 86_400, do: count(div(seconds, 3_600), "hour") <> " ago"
  defp ago(seconds), do: count(div(seconds, 86_400), "day") <> " ago"

  defp count(1, unit), do: "1 #{unit}"
  defp count(n, unit), do: "#{n} #{unit}s"

  defp descriptor_names do
    Descriptor.all()
    |> Enum.flat_map(&String.split(&1.label, ~r/[\s()]+/, trim: true))
    |> Enum.filter(&Regex.match?(~r/^[A-Z]/, &1))
  end
end
