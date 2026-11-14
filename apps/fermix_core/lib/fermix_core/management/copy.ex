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
  code or secret id does either.

  Beside them sit the rest of what an Always On screen shows (Always On
  setup §3.1, the Always On pane draft 3): a screen's one secondary sentence
  (the `*_note` and `*_waits` keys); the sentence each action's confirm asks
  (`summary_sentence/2`'s `confirm_*` keys, and `move_confirm/2` for Move
  now, built from the review's own warnings), one part per line and never
  with a time that moves with the clock (a restore names the absolute date
  of the backup it takes); the sentence of the step a move, a move back, a
  restore or a backup is in (`progress_*`); a notice's sentence
  (`notice_*`); the Details lines (`summary_line/3`), each a label and a
  value finished here, times stated absolutely in the owner's zone
  (`FermixCore.Clock`); a flow's steps (`step_labels/2`), its route
  (`route_here/1`) and the bytes it counted (`transfer_label/3`); the
  backup line and its words (`backup_words/1`); the Always On docs page
  with a screen's anchor (`always_on_docs_url/1`); the command for the
  owner's server (`own_server_command/0`), which carries no code, the
  sentence the code is shown with (`own_server`), and the one that also
  joins it to the owner's tailnet (`own_server_tailscale_command/0`, with
  `own_server_tailscale`'s sentence and `tailscale_label/0`); the systems,
  architectures and kernel the server's first boot takes, which the code's
  sentence names and the copy rules are given as data
  (`own_server_names/0`); and the words around the Tailscale Funnel mounts
  a server needs (`webhooks*`, `mount_label/1`).

  A screen's own words are short (the pane's rule R1): every summary key a
  screen draws as its sentence, its note, its progress or its webhooks says
  at most 20 words (`word_bound/0`), except the keys `unbounded_keys/0`
  names: a confirm, which says each warning in its own words; a notice, which
  is a system notification; the code's sentence, which names a date; the
  failure's own words a note carries; and the phone's message.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Clock
  alias FermixCore.Home.Disk
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
  @stays_here [
    voice: "voice calls",
    meetings: "meetings",
    accessories: "StackChan"
  ]
  # The features named alone in the singular.
  @singular_features [[:accessories]]
  # What reaches the server through Funnel, as the webhooks' sentence starts.
  @reached [whatsapp: "WhatsApp", cues: "your webhook sources"]
  # What a move back costs, each where the home has it.
  @return_costs [
    telegram: "Messages sent to Telegram while it moves wait until it is done."
  ]
  @summary_keys ~w(off connect connecting ready ready_waits moving waiting on on_backup
                   on_no_backup undone undone_refused undone_unmarked move_marker_unread
                   retired retired_back candidate_waiting
                   candidate_receiving primary cannot_reach cannot_reach_note
                   server_not_set_up server_waited_too_long update server_older
                   server_older_note update_settings_only server_ahead disk_full
                   server_disk_full disk_note backup_old backup_none server_backup_old
                   backup_failed backup_failed_note backup_push not_ready notice_ready
                   notice_moved notice_backup_week notice_server_backup_week
                   notice_server_lapsed notice_restored return_connecting return_ready
                   return_waits notice_return_ready return_moving return_undone return_failed
                   return_stopped restore_moving restore_failed notice_back progress_packing
                   progress_sending progress_unpacking progress_switching
                   progress_return_receiving progress_return_staged progress_return_placing
                   progress_restoring progress_backing_up confirm_restore_here
                   confirm_return_move confirm_forget confirm_change_passphrase webhooks
                   webhooks_whatsapp webhooks_cue webhooks_tailnet own_server
                   own_server_tailscale review_note notice_computer_review
                   notice_server_sandbox computer_asks join_dialing join_waiting
                   notice_computer_joined notice_computer_change)a
  # The sandbox's modes a change from a computer can name (`Sandbox.Config`).
  @sandbox_modes ~w(strict standard open)
  # The keys a screen does not draw as its own short words (the moduledoc).
  @unbounded_keys ~w(confirm_restore_here confirm_return_move confirm_forget
                     confirm_change_passphrase notice_ready notice_moved notice_backup_week
                     notice_server_backup_week notice_server_lapsed notice_restored
                     notice_return_ready notice_back notice_computer_review
                     notice_server_sandbox notice_computer_joined notice_computer_change
                     own_server backup_failed_note backup_push)a
  # The most words a screen's own sentence says (R1).
  @word_bound 20
  # Each Details line's label, by its key.
  @line_labels [
    server: "Server",
    system: "System",
    version: "Version",
    disk: "Server disk",
    move_back: "Move back",
    connection: "Connection",
    s3_bucket: "S3 bucket"
  ]
  @line_keys Keyword.keys(@line_labels) ++ [:backup, :copies]
  @docs_url "https://fermix.ai/docs/always-on/"
  # The docs page's anchors, one per screen family (the pane's §4): the
  # contract between the engine and the page.
  @docs_anchors ~w(what-you-need set-up-your-server tailscale the-move on-your-server webhooks
                   backups when-the-server-is-gone updates server-disk move-back add-a-computer)
  # A flow's steps, in order: the move, and the move back to this computer.
  @move_steps ["Connect your server", "Move now", "Send your home", "Switch over"]
  @return_steps ["Move now", "Receive your home", "Put Fermix in place"]
  @own_server_command "curl -fsSL https://fermix.ai/install | sudo sh -s -- --always-on --version "
  # The systems the server's first boot takes (`packaging/cloud/first-boot.sh`'s
  # `check_host`). Names the copy interpolates, so the version rule passes
  # them as data.
  @server_systems ["Debian 12", "Debian 13", "Ubuntu 24.04"]
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
    # Always On's step for a computer that joins the home, as its screens
    # label it (M97).
    "Add a computer",
    # Always On's step that moves the home, as its screens label it.
    "Move now",
    # The system of the server Always On moves to.
    "Linux",
    # The display server the Linux computer-use rows name.
    "Wayland",
    "Apple ID",
    "Apple",
    "Full Disk Access",
    "Automation",
    # The voice setting, named as the app labels it.
    "Talk to Fermix",
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
    # The Tailscale Funnel mounts of an Always On server's webhooks.
    "Tailscale Funnel",
    "Funnel",
    "Tailscale",
    "MagicDNS",
    # Meta's app dashboard, as WhatsApp's webhook form labels it.
    "Meta",
    "Callback URL",
    "Google Chrome for Testing",
    "Google Chrome Canary",
    "Google Chrome",
    "Chromium",
    "Chrome",
    "Google",
    "Android",
    "Node.js",
    "Atom",
    # The robot's own pairing prompt, its Matches confirm and its Forget
    # button, the Mac app's Pet destination, its Pair and Reconnect actions
    # and its This Mac voice device, named as the robot and the app show
    # them (M91).
    "Pair with this Mac",
    "Matches",
    "Forget",
    "Pair",
    "Pet",
    "Reconnect",
    "This Mac",
    # The Always On pane's section of this computer's switches, as it is
    # titled.
    "This computer",
    # The sandbox's modes and the coding pane's section, named as their
    # settings show them (M97 D28: what a change from a computer set, and
    # where the move's review says to allow coding agents on the server).
    "Strict",
    "Standard",
    "Open",
    "Coding agents",
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

  Provider labels are read from the descriptor registry, so a provider added
  in Elixir needs no entry here; the rest is the hand-maintained list this
  module documents.
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

  @doc """
  Why the server `to` turned a move down, for the undone screen's note
  (`FermixChannels.Home.MoveWorker`), from what it `said`: its own sentence
  after the plain one where that sentence is words an owner reads, breaking
  no copy rule and no summary rule and carrying no code (no brace, bracket
  or angle bracket: a server says so of its disk, or of a home in a newer
  form than it reads), and `:undone_refused`'s words where it is not (a
  protocol's words, a file's error), which the worker logs.
  """
  @spec move_refused(String.t(), String.t()) :: String.t()
  def move_refused(to, said) when is_binary(to) and is_binary(said) do
    said = String.trim(said)

    if owner_words?(said, to),
      do: turned_down(to) <> " " <> said,
      else: summary_sentence(:undone_refused, %{to: to})
  end

  defp owner_words?(said, to),
    do:
      said != "" and not String.match?(said, ~r/[{}\[\]<>]/) and
        violations(said, :prose, [to]) == [] and summary_violations(said) == []

  defp turned_down(to), do: "#{to} turned the move down, so nothing moved."

  @doc "Every key `summary_sentence/2` takes, so the copy gate walks them all."
  @spec summary_keys() :: [atom()]
  def summary_keys, do: @summary_keys

  @doc """
  The summary keys a screen does not draw as its own short words: confirms,
  notices, the code's sentence, a failure's own words and the phone's
  message. Every other key says at most `word_bound/0` words.
  """
  @spec unbounded_keys() :: [atom()]
  def unbounded_keys, do: @unbounded_keys

  @doc "The most words a screen's own sentence, note, progress or webhooks say (R1)."
  @spec word_bound() :: pos_integer()
  def word_bound, do: @word_bound

  @doc """
  One sentence of `home.status.summary`, by its key, with the values it
  names: `machine` ("Mac" or "computer"), `age` (seconds since the last
  backup), `days`, `percent`, `to` (the server's name), `at` and `zone` (a
  time, stated in the owner's zone), `place` and `error` (a failed backup's
  own words), `restore` (whether Restore here is offered).
  """
  @spec summary_sentence(atom(), map()) :: String.t()
  def summary_sentence(:off, %{machine: machine}),
    do: "Keep Fermix running when this #{machine} sleeps. It moves to a server you own."

  def summary_sentence(:connect, _values), do: "Waiting for your server to use its code."

  def summary_sentence(:connecting, _values), do: "Connecting your server…"

  def summary_sentence(:ready, _values),
    do: "Your server is ready. Fermix moves to it when you press Move now."

  def summary_sentence(:ready_waits, %{to: to, at: %DateTime{} = at, zone: zone})
      when is_binary(to),
      do: "#{to} waits for the move until #{stated(at, zone)}."

  # The code's sentence, under the command it names: the systems the
  # server's first boot takes, and until when the code works.
  def summary_sentence(:own_server, %{at: %DateTime{} = at, zone: zone}) do
    [debian12, debian13, ubuntu] = @server_systems
    [_debian, release] = String.split(debian13, " ")

    "Run this on your #{debian12} or #{release}, or #{ubuntu} server, then paste the code " <>
      "when it asks. The code works once, until #{stated(at, zone)}."
  end

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

  # Why a move was undone, as the move worker records it for the undone
  # screen's note (`FermixChannels.Home.MoveWorker`, `move_refused/2`): the
  # server's own code and message, and the reason a file could not be
  # written, go to the log.
  def summary_sentence(:undone_refused, %{to: to}) when is_binary(to),
    do: turned_down(to) <> " Fermix's log says why."

  def summary_sentence(:undone_unmarked, _values),
    do: "Fermix could not record that this home moved, so nothing moved. Its log says why."

  # A move whose marker cannot be read: whether this home moved is not known.
  def summary_sentence(:move_marker_unread, _values),
    do:
      "Fermix cannot read the file that says whether this home moved. Its log names it; fix " <>
        "it, then restart Fermix."

  def summary_sentence(:retired, %{machine: machine}),
    do: "Fermix moved to your server, and this #{machine} is no longer connected to it."

  def summary_sentence(:retired_back, %{to: to}) when is_binary(to),
    do: "This copy is retired: Fermix moved back to #{to}."

  def summary_sentence(:candidate_waiting, _values), do: "This server is waiting for its move."
  def summary_sentence(:candidate_receiving, _values), do: "Your home is moving to this server."
  def summary_sentence(:primary, _values), do: "Fermix runs here."

  def summary_sentence(:cannot_reach, _values),
    do: "Fermix cannot reach your server. Your messages wait until it is back."

  # What to check, and, where this computer can restore, when to.
  def summary_sentence(:cannot_reach_note, %{machine: machine, restore: restore?})
      when is_boolean(restore?) do
    "Check that your server is on and online." <>
      if(restore?,
        do: " If it is gone for good, restore Fermix on this #{machine}.",
        else: ""
      )
  end

  def summary_sentence(:server_not_set_up, _values),
    do:
      "This server did not finish setting up. Open a new code in Always On and run the " <>
        "command here again."

  def summary_sentence(:server_waited_too_long, _values),
    do:
      "This server waited too long. Open a new code in Always On and run the command " <>
        "here again."

  def summary_sentence(:update, %{machine: machine}),
    do: "Update Fermix on this #{machine} to keep using Always On."

  def summary_sentence(:update_settings_only, %{machine: machine}),
    do: "Your server runs a newer Fermix, so this #{machine} can change settings only."

  def summary_sentence(:server_older, %{machine: machine}),
    do: "Your server runs an older Fermix than this #{machine}."

  def summary_sentence(:server_older_note, _values),
    do: "It updates on its own once the app for each computer that keeps your backups carries it."

  def summary_sentence(:server_ahead, %{machine: machine}),
    do: "Your server runs a newer Fermix than this #{machine} can restore."

  def summary_sentence(:disk_full, %{percent: percent}),
    do: "Your server's disk is #{percent}% full."

  def summary_sentence(:server_disk_full, %{percent: percent}),
    do: "This server's disk is #{percent}% full."

  def summary_sentence(:disk_note, _values),
    do: "Free some space on it, or give it a bigger disk."

  def summary_sentence(:backup_old, %{days: days, machine: machine}),
    do: "Your last backup is #{days} days old. It runs when this #{machine} is online."

  def summary_sentence(:backup_failed, %{place: place}) when is_binary(place),
    do: "Backing up to #{place} failed."

  # The try's own words, then when it was tried.
  def summary_sentence(:backup_failed_note, %{at: %DateTime{} = at, zone: zone} = values),
    do: "#{terminated(values.error)} Tried #{stated(at, zone)}."

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

  def summary_sentence(:not_ready, _values), do: "The move cannot start yet."

  def summary_sentence(:notice_ready, _values), do: "Your server is ready for the move."
  def summary_sentence(:notice_moved, _values), do: "Fermix moved to your server."

  def summary_sentence(:notice_backup_week, %{machine: machine}),
    do: "Your last backup is a week old. It runs when this #{machine} is online."

  def summary_sentence(:notice_computer_review, %{machine: machine}),
    do:
      "Fermix on your server can use nothing on this #{machine} until you review what it " <>
        "may use."

  # While a linked computer's switches wait for the owner's review: they are
  # set under This computer, and Keep these switches takes them as they are.
  def summary_sentence(:review_note, %{machine: machine}),
    do:
      "Fermix on your server can use nothing on this #{machine} until you review the " <>
        "switches under This computer."

  def summary_sentence(:notice_server_sandbox, _values),
    do:
      "This server now uses its own sandbox setting: open. The settings it had from your " <>
        "computer stay on that computer."

  def summary_sentence(:notice_server_backup_week, _values),
    do: "The last backup is a week old. It runs when your Mac is online."

  def summary_sentence(:computer_asks, %{name: name, system: system}),
    do:
      "A computer named #{name} (#{system}) asks to join your Fermix. To add it, type the " <>
        "six digits it shows."

  def summary_sentence(:join_dialing, %{machine: machine, to: to}),
    do: "Connecting this #{machine} to your Fermix on #{to}."

  def summary_sentence(:join_waiting, %{machine: machine, to: to, sas: sas}),
    do: "Type #{digits(sas)} on #{to}, where it asks you to add this #{machine}."

  def summary_sentence(:notice_computer_joined, %{name: name}),
    do: "A computer named #{name} joined your Fermix."

  # The server's sandbox or coding approval changed from the computer `name`
  # (M97 §19.5): `server` is `:this` on the server itself, `:yours` on a
  # computer that knows no name for it, else the name it knows it by.
  def summary_sentence(:notice_computer_change, %{name: name, change: change, server: server})
      when is_binary(name),
      do: computer_change(change, server, name)

  def summary_sentence(:notice_server_lapsed, _values),
    do:
      "Your server waited 24 hours for the move and must be set up again. Open a new code " <>
        "in Always On and run the command on it again."

  def summary_sentence(:notice_restored, %{machine: machine, day: day}) when is_binary(day),
    do: "Fermix runs on this #{machine} again, from its backup of #{day}."

  def summary_sentence(:return_connecting, %{machine: machine}),
    do: "Connecting this #{machine} to your server…"

  def summary_sentence(:return_ready, %{machine: machine}),
    do:
      "Fermix still runs on your server. It moves back to this #{machine} when you press Move now."

  def summary_sentence(:return_waits, %{machine: machine, at: %DateTime{} = at, zone: zone}),
    do: "This #{machine} waits for it until #{stated(at, zone)}."

  def summary_sentence(:notice_return_ready, %{machine: machine}),
    do:
      "Fermix still runs on your server. Open Always On and press Move now to move it back " <>
        "to this #{machine}."

  def summary_sentence(:return_moving, %{machine: machine}),
    do: "Moving Fermix back to this #{machine}. Messages wait until it is done."

  def summary_sentence(:return_undone, _values),
    do: "The move back was undone. Fermix still runs on your server."

  def summary_sentence(:return_failed, %{machine: machine}),
    do: "This #{machine} could not get ready to take Fermix back. Move back to try again."

  def summary_sentence(:return_stopped, _values),
    do: "Moving back stopped part-way, so cancel it and move back again."

  def summary_sentence(:restore_moving, %{machine: machine}),
    do: "Restoring Fermix on this #{machine} from its backup. Messages wait until it is done."

  def summary_sentence(:restore_failed, %{machine: machine}),
    do: "Fermix could not restore its backup on this #{machine}."

  def summary_sentence(:notice_back, %{machine: machine}),
    do:
      "Fermix is back on this #{machine}. Your own server still runs its retired copy: turn " <>
        "it off or delete it."

  def summary_sentence(:progress_packing, _values), do: "Packing your home…"

  def summary_sentence(:progress_sending, %{to: to}) when is_binary(to),
    do: "Sending your home to #{to}…"

  def summary_sentence(:progress_unpacking, %{to: to}) when is_binary(to),
    do: "#{to} is unpacking your home…"

  def summary_sentence(:progress_switching, %{to: to}) when is_binary(to),
    do: "Switching over to #{to}…"

  def summary_sentence(:progress_return_receiving, _values),
    do: "Receiving your Fermix from the server…"

  def summary_sentence(:progress_return_staged, _values),
    do: "Waiting for your server to hand over…"

  def summary_sentence(:progress_return_placing, %{machine: machine}),
    do: "Putting Fermix in place on this #{machine}…"

  def summary_sentence(:progress_restoring, %{machine: machine}),
    do: "Restoring Fermix from the backup on this #{machine}…"

  def summary_sentence(:progress_backing_up, _values), do: "Backing up now…"

  # The date of the backup it restores, stated absolutely: no time that
  # moves with the clock.
  def summary_sentence(:confirm_restore_here, %{
        machine: machine,
        telegram: telegram?,
        at: %DateTime{} = at,
        zone: zone
      })
      when is_boolean(telegram?) do
    lines([
      "Restore Fermix on this #{machine} from its backup of #{stated(at, zone)}?",
      "Confirm only once you deleted your server, or stopped it for good: if it runs again, " <>
        "two copies of Fermix answer the same channels.",
      "Messages, memory and jobs since that backup are gone" <>
        if(telegram?, do: ", and Telegram keeps nothing older than 24 hours.", else: ".")
    ])
  end

  def summary_sentence(:confirm_forget, _values),
    do:
      lines([
        "Forget this server?",
        "Fermix stops holding it for the move. To move later, set up a server with a new code."
      ])

  def summary_sentence(:confirm_change_passphrase, _values),
    do:
      lines([
        "Change the recovery passphrase?",
        "Backups made before now still open only with the passphrase you set before."
      ])

  def summary_sentence(:confirm_return_move, %{
        machine: machine,
        stays_here: features,
        costs: costs
      }),
      do:
        lines(
          ["Move Fermix back to this #{machine} now?"] ++
            runs_here_line(features) ++
            Enum.map(costs, &Keyword.fetch!(@return_costs, &1)) ++
            ["Your server stays until you delete it."]
        )

  def summary_sentence(:webhooks, %{carried: [_ | _] = carried}) do
    names = for {kind, name} <- @reached, kind in carried, do: name
    true = length(names) == length(Enum.uniq(carried))
    verb = if carried == [:whatsapp], do: "needs", else: "need"

    "#{names |> join_names() |> capitalised()} #{verb} a public address to reach your " <>
      "server. Run each command once, on the server."
  end

  def summary_sentence(:webhooks_whatsapp, _values),
    do: "Then set the address it prints as Meta's Callback URL, with your verify token."

  def summary_sentence(:webhooks_cue, _values),
    do: "In the sender, change the host of the source's webhook address to the one it prints."

  # The one step a tailnet takes once, under the mounts.
  def summary_sentence(:webhooks_tailnet, _values),
    do:
      "These use Tailscale Funnel. Once per tailnet, let tag:fermix-server use Funnel, and " <>
        "turn on MagicDNS and HTTPS certificates."

  def summary_sentence(:own_server_tailscale, _values),
    do:
      "For WhatsApp and webhook sources: run this instead. It also asks for a one-off, " <>
        "pre-approved Tailscale auth key tagged tag:fermix-server."

  @doc """
  What a move stops among `features` (`:voice`, `:meetings`,
  `:accessories`), as a sentence starts: "Voice calls and meetings stop
  after the move", "StackChan stops after the move".
  """
  @spec stops_after_move([:voice | :meetings | :accessories, ...]) :: String.t()
  def stops_after_move([_ | _] = features) do
    names = for {feature, name} <- @stays_here, feature in features, do: name
    true = length(names) == length(Enum.uniq(features))
    verb = if features in @singular_features, do: "stops", else: "stop"

    "#{names |> join_names() |> capitalised()} #{verb} after the move"
  end

  @doc """
  What a move does to voice calls, as a sentence without its full stop: this
  `machine`'s own calls stop, since they reach only its socket, and the
  phone's carry on at `server`, where its session goes (M87 §07).
  """
  @spec voice_after_move(String.t(), String.t()) :: String.t()
  def voice_after_move(machine, server) when is_binary(machine) and is_binary(server) do
    "This #{machine}'s voice calls stop after the move; calls from your phone carry on at " <>
      "#{server} when Talk to Fermix is on there and its key is in #{server}'s secret store"
  end

  @doc """
  What a move back brings back among `features` (`:voice`, `:meetings`,
  `:accessories`) on the computer `name` it returns to, as a sentence starts:
  "Voice calls and meetings run on studio-mac again after the move".
  """
  @spec runs_again([:voice | :meetings | :accessories, ...], String.t()) :: String.t()
  def runs_again([_ | _] = features, name) when is_binary(name) do
    names = for {feature, label} <- @stays_here, feature in features, do: label
    true = length(names) == length(Enum.uniq(features))
    verb = if features in @singular_features, do: "runs", else: "run"

    "#{names |> join_names() |> capitalised()} #{verb} on #{name} again after the move"
  end

  defp runs_here_line([]), do: []

  defp runs_here_line(features) do
    verb = if features in @singular_features, do: "runs", else: "run"
    ["#{feature_names(features)} #{verb} here again."]
  end

  # A confirm's parts, one per line: the question, then each thing it says.
  # An alert, a sheet, a terminal and the setup page draw a line break as it
  # is.
  defp lines(parts), do: Enum.join(parts, "\n")

  # What runs only on this computer among `features`, named in order, as a
  # sentence starts.
  defp feature_names(features) do
    names = for {feature, name} <- @stays_here, feature in features, do: name
    true = length(names) == length(Enum.uniq(features))
    names |> join_names() |> capitalised()
  end

  defp join_names([name]), do: name
  defp join_names(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  # A sentence's first letter, unless the first word is iMessage.
  defp capitalised("iMessage" <> _rest = text), do: text
  defp capitalised(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  @doc """
  Move now's confirm, one part per line: the question with the way back to
  this `machine`, then each warning of the review in its own words
  (`warnings`, the sentences, in the review's order).
  """
  @spec move_confirm([String.t()], String.t()) :: String.t()
  def move_confirm(warnings, machine) when is_list(warnings) and is_binary(machine),
    do:
      lines([
        "Move Fermix to your server now? You can move it back to this #{machine} any time."
        | warnings
      ])

  @doc "Every key `summary_line/3` takes."
  @spec summary_line_keys() :: [atom()]
  def summary_line_keys, do: @line_keys

  @doc "The label of the Details line `key` (`summary_line_keys/0`)."
  @spec summary_line_label(atom()) :: String.t()
  def summary_line_label(:backup), do: "Last backup to your desktop"
  def summary_line_label(:copies), do: "Backups on this Mac"
  def summary_line_label(key), do: Keyword.fetch!(@line_labels, key)

  @doc """
  One Details line, `%{"label", "value"}`, its value finished here from
  `value`: a name, a system, a version or an S3 bucket as it is; a
  `backup`'s `{place, at}` stated in `ctx`'s `zone`; the space this
  computer's `copies` take, in bytes, on `ctx`'s `machine`; how full the
  server's `disk` is, a fraction; why Move back is not offered (`move_back`,
  the move back's own refusal); and whether the link to the server runs
  direct or through Fermix's relay (`connection`, `:direct` or `:relay`).
  """
  @spec summary_line(atom(), term(), map()) :: %{String.t() => String.t()}
  def summary_line(:backup, {place, %DateTime{} = at}, %{zone: zone}),
    do: line("Last backup to #{place}", stated(at, zone))

  def summary_line(:copies, bytes, %{machine: machine}) when is_integer(bytes),
    do: line("Backups on this #{machine}", Disk.gib(bytes))

  def summary_line(:disk, used, _ctx) when is_number(used),
    do: line(summary_line_label(:disk), "#{round(used * 100)}% used")

  def summary_line(:connection, :direct, _ctx),
    do: line(summary_line_label(:connection), "Direct")

  def summary_line(:connection, :relay, _ctx),
    do: line(summary_line_label(:connection), "Through Fermix's network")

  def summary_line(key, value, _ctx)
      when key in [:server, :system, :version, :move_back, :s3_bucket] and is_binary(value),
      do: line(summary_line_label(key), value)

  defp line(label, value), do: %{"label" => label, "value" => value}

  @doc """
  A flow's steps, in order: the move to the owner's server (`:move`) and
  the move back to this `machine` (`:return`), whose first step names it.
  """
  @spec step_labels(:move | :return, String.t()) :: [String.t(), ...]
  def step_labels(:move, machine) when is_binary(machine), do: @move_steps

  def step_labels(:return, machine) when is_binary(machine),
    do: ["Get this #{machine} ready" | @return_steps]

  @doc "This computer as a flow's route names its end: This Mac, or This computer off a Mac."
  @spec route_here(String.t()) :: String.t()
  def route_here(machine) when is_binary(machine), do: "This #{machine}"

  @doc """
  The bytes a move counted, as the route's words: `bytes` of `size`, `:sent`
  (the source) or `:received` (the computer taking the home back), "502 MiB
  of 1.4 GiB sent". Sizes under a GiB in whole MiB, larger ones in GiB to
  one decimal.
  """
  @spec transfer_label(non_neg_integer(), pos_integer(), :sent | :received) :: String.t()
  def transfer_label(bytes, size, way)
      when is_integer(bytes) and bytes >= 0 and is_integer(size) and size > 0 and
             way in [:sent, :received],
      do: "#{size_words(bytes)} of #{size_words(size)} #{way}"

  @gib 1_073_741_824
  @mib 1_048_576

  defp size_words(bytes) when bytes < @gib, do: "#{div(bytes + div(@mib, 2), @mib)} MiB"

  defp size_words(bytes) do
    tenths = div(bytes * 10 + div(@gib, 2), @gib)
    "#{div(tenths, 10)}.#{rem(tenths, 10)} GiB"
  end

  @doc """
  The backup words a server's backup settings show (the pane's §3.12): the
  recovery passphrase's label, whether one is `set?`, its footer, and the
  line that says a copy is kept in S3.
  """
  @spec backup_words(boolean()) :: %{
          label: String.t(),
          value: String.t(),
          footer: String.t(),
          s3: String.t()
        }
  def backup_words(set?) when is_boolean(set?) do
    %{
      label: "Recovery passphrase",
      value: if(set?, do: "Set", else: "Not set"),
      footer: "Every backup is encrypted to it, and Fermix never stores it.",
      s3: "Also kept in S3, set up with your server."
    }
  end

  defp stated(at, zone), do: Clock.stated_instant(at, personalization: [timezone: zone])

  defp terminated(text) when is_binary(text) do
    if String.ends_with?(text, [".", "?", "!"]), do: text, else: text <> "."
  end

  @doc """
  The names the own-server copy interpolates rather than writes: the systems
  the server's first boot takes (the code's sentence), which the copy rules
  are given as data. Its architectures and kernel are the docs page's.
  """
  @spec own_server_names() :: [String.t()]
  def own_server_names, do: @server_systems

  @doc "Every anchor of the Always On docs page a screen links to (the pane's §4)."
  @spec docs_anchors() :: [String.t()]
  def docs_anchors, do: @docs_anchors

  @doc "The Always On docs page at `anchor` (`docs_anchors/0`), a screen's help."
  @spec always_on_docs_url(String.t()) :: String.t()
  def always_on_docs_url(anchor) when anchor in @docs_anchors, do: @docs_url <> "#" <> anchor

  @doc "The label the optional Tailscale step of the code is folded under."
  @spec tailscale_label() :: String.t()
  def tailscale_label, do: "Also join your tailnet (optional)"

  @doc """
  The command an owner runs on a Linux server of their own to install Fermix
  there: the regular installer with `--always-on`, which runs that
  release's own server script (`packaging/cloud/first-boot.sh`) once its
  digest matches fermix.ai's. It carries no code, which the server's first
  boot asks for on the terminal without echo, so the code never lands in its
  shell history, and it names the release this computer runs, which the
  server installs (a server runs exactly its desktop's Fermix, so the home
  can move back): `version`, this engine's own unless given.
  """
  @spec own_server_command(String.t()) :: String.t()
  def own_server_command(version \\ BuildInfo.product_version()) when is_binary(version),
    do: @own_server_command <> version

  @doc """
  `own_server_command/0` with the optional Tailscale step (`--tailscale`):
  the server joins the owner's tailnet before it enrolls, with an auth key
  the owner creates tagged `tag:fermix-server`. The server asks for the code
  and then the key at the terminal, without echo, so neither is on a command
  line or in a shell history (`TS_AUTHKEY` is cloud-init's, never printed
  here).
  """
  @spec own_server_tailscale_command(String.t()) :: String.t()
  def own_server_tailscale_command(version \\ BuildInfo.product_version())
      when is_binary(version),
      do: own_server_command(version) <> " --tailscale"

  @doc """
  The label of one Tailscale Funnel mount, by what it carries: WhatsApp's,
  or a cue webhook source's (`{:cue, ref}`), which names the source.
  """
  @spec mount_label(:whatsapp | {:cue, String.t()}) :: String.t()
  def mount_label(:whatsapp), do: "WhatsApp"
  def mount_label({:cue, ref}) when is_binary(ref), do: "Webhook source #{ref}"

  @doc """
  The label of one summary action, by its id; `cancel` closes a code
  (`code`) or forgets a held server (`forget`), `own_server` beside an open
  code opens a new one that ends it (`renew`), and `move_back` and
  `restore_here` name this computer (`machine`).
  """
  @spec summary_label(atom(), map()) :: String.t()
  def summary_label(:cancel, %{code: true}), do: "Cancel the code"
  def summary_label(:cancel, %{forget: true}), do: "Forget this server"
  def summary_label(:cancel, _values), do: "Cancel"
  def summary_label(:move_now, _values), do: "Move now"
  def summary_label(:try_again, _values), do: "Try again"

  def summary_label(:update, %{first: true, machine: machine}),
    do: "Update Fermix on this #{machine} first"

  def summary_label(:update, _values), do: "Update"
  def summary_label(:back_up_now, _values), do: "Back up now"
  def summary_label(:check_again, _values), do: "Check again"
  def summary_label(:review_offers, _values), do: "Keep these switches"
  def summary_label(:add_computer, _values), do: "Add a computer"
  def summary_label(:approve_computer, _values), do: "Add it"
  def summary_label(:deny_computer, _values), do: "Do not add it"
  def summary_label(:change_passphrase, _values), do: "Change"

  def summary_label(:restart_server, %{name: name}) when is_binary(name) and name != "",
    do: "Restart #{name}"

  def summary_label(:own_server, %{renew: true}), do: "Replace the code"

  def summary_label(:own_server, _values), do: "Use my own Linux server"
  def summary_label(:move_back, %{machine: machine}), do: "Move back to this #{machine}"
  def summary_label(:restore_here, %{machine: machine}), do: "Restore on this #{machine}"

  # A change from a computer, in the words the sandbox's settings row and the
  # coding pane use: the mode's own title, and whether agents may run there.
  defp computer_change({:sandbox_mode, mode}, server, name) when mode in @sandbox_modes,
    do: "#{possessive(server)} sandbox was set to #{String.capitalize(mode)} from #{name}."

  defp computer_change({:harness_approved, true}, server, name),
    do: "Coding agents were allowed to run on #{named(server)} from #{name}."

  defp computer_change({:harness_approved, false}, server, name),
    do: "Coding agents were turned off on #{named(server)} from #{name}."

  defp possessive(:this), do: "This server's"
  defp possessive(:yours), do: "Your server's"
  defp possessive(name) when is_binary(name), do: name <> "'s"

  defp named(:this), do: "this server"
  defp named(:yours), do: "your server"
  defp named(name) when is_binary(name), do: name

  # Six digits as a person reads them aloud: two groups of three.
  defp digits(<<first::binary-size(3), rest::binary-size(3)>>), do: first <> " " <> rest
  defp digits(sas) when is_binary(sas), do: sas

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
