# The home's computers (Always On)

Once the home runs on an Always On server, every computer linked to it is a
member of the home: the computer the home moved from, and every computer
the owner added with a code (*Adding a computer*). The server keeps a record of each,
and each computer decides for itself what Fermix on the server may use on
it. The server reads, writes and searches files and runs commands and git on
a computer that offers them (*Files and commands on a computer*) and uses
its browser (*A computer's browser* in the `browser` reference) and its
screen (*A computer's screen*), and a Mac's Messages carry the home's
iMessage (*iMessage through a Mac*). The move, the link and the summary: skill_view(name:
"self-knowledge", file: "home").

## The record

- On the server each computer has a name, unique in the home; its system
  (macOS or Linux); the Fermix version it runs; whether it is connected, and
  since when, or away, and when the home last heard from it; the path its
  session runs while connected (`direct`, or `relay` through Fermix's
  relay); what it offers; and whether it keeps copies of the home's backups
  (the computer the home moved from does).
- `home.status` lists them as `computers` (`device_id`, `name`, `platform`,
  `engine_version`, `connected`, `since`, `last_seen`, `path`, `offers`,
  each with its `label`, `backups`, and `this_computer`, true on a linked
  computer's own row in the list it reads from its server), beside
  `desktops`, which stays for the apps that read it;
  `fermix home status --json` shows the same. Only the server lists them: on
  a computer `computers` is empty, and `primary` is its link to the server.
- A computer that is away is still listed, with what it last offered and the
  version it last ran, which the server keeps on its own disk. A connected
  one stands as its session's hello found it; one whose version is not known
  is served settings only, as one past the window is: no chat, no requests,
  no history.
- **Names.** The owner can rename a computer with the management method
  `computers.rename` (`device_id`, `name`), answered on the server (a
  computer's app forwards it there). A name is one line of at most 64
  characters, and no other computer of the home, nor the server, may already
  have it, compared without case. Its refusals: "Give the computer a name of
  one line, at most 64 characters.", "Another computer of yours is already
  called <name>.", "Your server is already called <name>.", "Your Fermix has
  no such computer." No `fermix` command renames a computer, and the agent
  has no tool for it.

## Adding a computer

Any computer with Fermix can join a home that already runs. Nothing moves:
the new computer keeps its own key, its link and its own settings, and holds
no memory of its own.

1. **Open a code.** On a computer already in the home: Always On > Details >
   **Add a computer**. On the server: `fermix always-on add-computer`. The
   code works once, for 30 minutes, for a computer and nothing else. Only
   one code is open at a time: while a code for the owner's own server is
   open, Add a computer is refused until that one is used or cancelled, and
   a new computer code replaces an older one.
2. **Enter it on the new computer.** In the app's first-run screen, the
   choice to connect to a Fermix that already runs (management
   `computer.join.start`). With no app: stop Fermix there, run `fermix
   computer join` and paste the code when it asks (or pipe it in; it is never
   an argument), then start Fermix.
3. **Type six digits.** Only the new computer shows them: "Type 482 913 on
   <server>, where it asks you to add this Mac." The Always On screen of the
   server and of every linked computer says "A computer named loft-linux
   (Linux) asks to join your Fermix. To add it, type the six digits it
   shows.", with **Add it** (type the digits read on the new computer; on
   the server `fermix always-on approve-computer --sas 482913`) and **Do not
   add it** (`deny-computer`). The digits come from the encrypted connection
   itself, so typing them proves the computer being added is the one in
   front of the owner, and someone who only saw the code cannot make them
   match. A phone cannot add a computer yet.

- Until the owner adds it, the new computer has no access and no record.
  Not adding it, typing digits that are not its own ("Those digits are not
  the ones the new computer showed, so it was not added. Open a new code to
  try again.") and the 30 minutes running out add nothing, and the code is
  spent each time: open a new one. A connection that drops while it waits
  spends nothing: it reconnects with new digits, and those are the ones to
  type. **Cancel** on the new computer makes it its own Fermix again.
- Once added it is listed at once, under the name it gave (with " 2" when
  another device has that name), and the owner's other surfaces are told "A
  computer named loft-linux joined your Fermix." It starts with every offer
  off (switched on at that computer, below), keeps no copies of the home's
  backups, and has no Move back or Restore here: those belong to the
  computer the home moved from. Its readiness judges only its sandbox: the
  server runs the turns, providers and channels.
- A computer that already has a Fermix of its own is refused by name, and
  nothing is deleted to make room: "This computer already has a Fermix of
  its own (it holds <what>), so it cannot join another. Two homes cannot be
  merged." What counts: any message, memory, scheduled job or computer
  history note, a paired phone or computer, a home that moved to a server, or
  a link to one. Memories that only repeat its settings (the owner's name,
  time zone and style and the assistant's name, which its first start and
  every settings save write) do not count, so a computer whose Fermix has
  started, or whose owner finished setting it up, can still join; they stay
  where they are, and nothing reads them while it is a computer. A code for
  the owner's own server ("That code sets up a server of your own, so a
  computer cannot join with it."), an expired one and a second join while
  one runs are refused too.
- **A computer's key** is in its own secret store (the Keychain on a Mac,
  the keyring on Linux, the file store where the owner chose it), named by
  the home's profile; it never travels in a move or a backup, and a
  disconnect or a move back deletes it.

## Removing a computer

- **From the home.** Remove it from the devices (the apps' device list, or
  `fermix devices revoke <id>` on the server; management
  `mobile.devices.revoke`): its link ends, the server forgets what it
  offered, and it comes back only by joining again with a new code. The one
  computer that keeps the only copies of the server's backups asks first:
  "<name> keeps the only copies of your server's backups. Remove it anyway?"
  (`--yes` on the terminal).
- **From the computer.** **Disconnect this computer** (management
  `computer.disconnect`) tells the server, then deletes that computer's key,
  its link and what the server may use on it. A computer that joined is its
  own Fermix again; the one the home moved from stays retired, with its own
  copies of the backups. A server that cannot be told asks first: "Fermix
  could not tell your server. Disconnect anyway? Your server lists this
  computer until you remove it there." The link goes last, so a disconnect
  that fails part-way leaves the computer linked, and asking again finishes.
- Adding, removing and disconnecting are the owner's decisions: the agent
  has no tool for them, and a command Fermix runs is refused.

## What a computer offers

Each computer works out what it offers from its own switches (below) and its
own machine, and sends the list to the server when its session starts, at
once when a switch changes, and within a minute of anything else changing (a
helper installed, a permission given, its sandbox mode). The server never
infers an offer: a connected computer that has not said what it offers yet
offers nothing, and so does one whose list the server refused (the server's
log says why).

| Offer (`id`) | What it is | Where it can be on |
|---|---|---|
| Files (`files`) | reading, writing, editing and searching files inside that computer's sandbox roots | Mac, Linux |
| Commands (`shell`) | commands held to that computer's sandbox, in its mode (`strict`, `standard` or `open`) | Mac; Linux whose kernel holds commands to the sandbox (Landlock) |
| The browser (`browser`) | that computer's browser profiles, pane and granted tabs | Mac, Linux |
| Your screen (`computer_use`) | seeing and controlling its screen | Apple silicon Mac or Linux x86_64, with the Computer Use helper installed and not refused the permission to see and control the screen |
| Messages (`imessage`) | the iMessage channel, through that Mac's Messages | Mac only |
| Your computer history (`history`) | recording activity there for computer history | Mac only for now |
| Apple Maps (`places`) | looking places up in Apple Maps for the server's place search (the `web` reference) | Mac with the Fermix app, whose engine carries the Apple Maps helper |

What reaches the server from a computer (a call, an attached file, a robot,
a notification) is no offer and has no switch: each follows its own
feature's setting. A voice call from a computer's app runs on the server,
on its Talk to Fermix, as a phone's does, held as `computer:<device id>`
(skill_view(name: "self-knowledge", file: "voice")); a file attached in a
computer's chat is uploaded to the server by that computer's Fermix and
reaches the turn as a phone's does (skill_view(name: "self-knowledge",
file: "companion")).

A reminder for "this computer" that comes due on the server rings on the
computers instead (skill_view(name: "self-knowledge", file:
"events_reminders")): the server asks each connected one, at most sixteen,
to show it, and each shows it the way its own home would. That is no offer
either and has no switch of its own: the master switch alone gates it, with
the system's own notification permission, and a Snooze pressed there goes
back to the server, which holds the reminder.

Each offer is in one of three states, in the computer's own words when it is
not on ("Mac" reads "computer" off a Mac):

- **on**, commands with their sandbox mode;
- **off**, and why: switched off ("Switched off on this Mac. Only someone at
  this Mac can switch it on."), the master switch off ("Everything Fermix on
  your server may use is switched off on this Mac."), or a review in wait
  ("Waiting for you to review what Fermix on your server may use on this
  Mac.", below);
- **unavailable**, and what is missing: "Messages runs only on a Mac.",
  "Fermix records computer history only on a Mac for now.", "Looking places
  up in Apple Maps needs the Fermix app on a Mac.", "The Fermix
  Computer Use helper is not installed on this Mac.", "This Mac has not
  allowed Fermix Computer Use to see and control the screen.", "Fermix cannot
  see or control the screen on this kind of processor.", "Commands need the
  kernel to hold them to the sandbox, and this computer's kernel does not.".

Another computer may offer something this server has no word for; it is
listed as it came.

## Each computer's switches

- What Fermix on the server may use on a computer is that computer's own
  choice: the `[fermix_core.computer]` section of its `machine.toml` (the
  `config` reference): `enabled`, the master switch; `reviewed`; and
  `files_and_shell` (files and commands together: a command reads the same
  files in the same sandbox), `browser`, `computer_use`, `imessage` and
  `places` (Apple Maps, for the server's place search). An offer is on only
  while the master is on, its switch is on and the switches are reviewed.
  Computer history has no switch here: its history
  offer is on while its recorder is on (the Computer history section, the
  `computer_history` reference) with the master on, and only then does the
  server take its sittings. An absent switch is off, but an absent `places`
  is on; an absent `enabled` or `reviewed` is on. A computer that joins or
  moves starts with Apple Maps on unless the owner unticks it. Each value is `true` or `false`; anything else keeps
  Fermix from starting, naming the key. A section an earlier Fermix wrote
  (a switch each for `files`, `shell` and `history`, and four for what
  reaches the server) is rewritten once at start: files and commands stay on
  only where both were, and on a computer linked to its server whose old
  history switch was off its recorder goes off too, so nothing the server did
  not have is sent (turn Computer history on at that computer to share it).
- In the app it is the **This computer** settings section of the Always On
  pane, on that computer: **Fermix on your server may use this computer**
  (the master: "Off stops everything Fermix on your server does here, from
  its next request."), **Files and commands**, **The browser**, **Your
  screen**, and on a Mac **Messages** and **Apple Maps**. While a review waits, the master's
  footer says so, and changing any switch is the review. It shows only on a
  computer linked to its server where Always On is offered: a computer that
  never moved has none, and the server has none. On a Linux computer without
  the app, `fermix settings set computer computer_files_and_shell=false`
  (each key is `computer_` and the switch) changes it from that computer.
- Every switch is live: no restart, and the computer sends its offers again
  at once.
- Only someone at that computer changes its switches. Its `machine.toml`
  never travels with the home, and no agent command or file tool can read or
  write it; the server never shows the section and refuses a write to it
  forwarded over the link ("This request configures the computer it came
  from, so the server does not answer it."). In this release switching an
  offer off is done at the computer too.

## What the server can never do on a computer

Whoever asks, and from whatever surface, Fermix on the server cannot turn an
offer on, change a computer's sandbox mode, add a folder grant there, answer
a macOS permission prompt, change who iMessage may write to, or read a
website password saved there: each is done at that computer. What remains:
with files and commands on and that computer's sandbox `open`, a server
that is taken over could read and change the account's files there, which
is why the move's review warns of it.

## What the server asks of a computer, and that computer's record

The link carries a request from the server to a computer and its answer
back: each file, command or git call a turn makes on a computer is one
request (*Files and commands on a computer*), and so is each reminder the
server rings there, one request per connected computer, which no turn made
(its kind is background).

- **The computer decides.** It refuses a request from an older copy of the
  home, anything while its master switch is off, and what its own switch
  for that offer has off, before anything runs; switching the master off
  also ends what is running ("The person at studio Mac stopped it."), and
  switching one offer off (the browser, the screen, Messages, files or
  commands) ends what runs or waits there for it, answered switched off with
  the same sentence a new request gets, the browser's tabs for the server
  included; other offers' work goes on. It runs at most 8 requests at once
  with 32 waiting, and refuses past that; when its request handler restarts,
  the waiting ones are answered at once as not run ("Fermix on this computer
  restarted before it ran this, so it did not run."), and it tells the
  server, which asks again about whatever it still waits on there.
- **The kind of turn that asked is the server's word.** Each request names
  it (a chat, a call, a scheduled run, a cue, a worker, background), and the
  computer applies its own rules to it. That check guards against a bug on
  the server, not against a server that was taken over.
- **Every request ends one way:** done, failed (in the computer's words),
  refused (switched off, unavailable, outside its sandbox, only while the
  owner is in the conversation, stopped at the computer, busy, an older copy
  of the home), timed out, cancelled, or not known. A tool that ran there
  and failed (a command that exited with an error, a file it could not
  read) is failed, never done: the journal says so, and the reply carries
  the tool's whole error.
- **Not known.** Something that changes that computer is never sent twice
  by the link. When its answer is lost (the session dropped, the computer
  restarted), Fermix says so in a sentence of its own: "Fermix lost studio
  Mac's answer, so whether <what> happened is not known. Check before doing
  it again." Check, or tell the owner; never repeat it on a guess. A read
  is simply asked once more. One that ran but whose output was lost on the
  way says so ("studio Mac ran it, but its output was lost on the way back,
  so it is not run again."); a file the browser saved for the server stays
  on that computer for a day, at the path the reply names.
- **The receipt and the journal.** The computer writes each request to its
  own journal before it runs and again when it ends: when, what kind (the
  offer and operation), what it acted on (a path, a host or an action), the
  kind of turn, how it ended and how long it took. Never the content: no
  file bytes, command output or page text. It keeps the newest 2,000
  requests of the last 7 days, on that computer, in a folder no agent
  command or file tool can read or write, and the server cannot edit it.
  The owner reads it there: the management method `computer.journal.list`
  (`limit` 1 to 200, `before`), answered only on that computer, which its
  app shows as "What Fermix did on this computer". No `fermix` command and
  no agent tool lists it.

## What a moved computer keeps on

- When the home moves to a server, the computer it leaves keeps what it had:
  files and commands (in the sandbox mode it already has), the browser, and
  the screen, Messages and computer history where their own settings had
  them on (Messages and history on a Mac only). Move now's review shows it as
  a block of its own: a sentence ("After the move, Fermix on your server can
  still use this Mac for: files and commands, in this Mac's sandbox
  (Standard), the browser, your screen. Change this here."), one line each
  (files and commands are one),
  and, where files and commands stay on while the sandbox is `open`, the
  warning "With files and commands on and this Mac's sandbox open, a server
  that is taken over can read and change this account's files on this Mac."
  The owner can untick any line before starting. The choice is written to
  that computer when the move commits (the history line sets its recorder,
  on or off), so a move that is undone leaves nothing, and Try again after
  it moves with the same choice, never the defaults.
- A computer that joins later starts with everything off, its recorder too.
- A computer that moved to its server with an earlier Fermix offers nothing
  until the owner reviews it. At its first start on this Fermix its switches
  are set as a move would have kept them, waiting for the review; Always On
  tells the owner once, as a notification, "Fermix on your server can use
  nothing on this Mac until you review what it may use.", and its Details
  show the block with **Review what your server may use**, which keeps the
  ticked lines on and turns the rest off; its history line is ticked where
  the recorder is on, and sets it. Changing any switch of the **This
  computer** section counts as the review too. A review is never taken
  back. From a terminal, on a home the Mac app does not manage: `fermix
  always-on review-offers`.

## The server's own sandbox

An Always On server has its own `machine.toml`. A server whose first start
on this Fermix left out the machine settings it had inherited from the
computer its home came from uses its own sandbox setting, `open`, and its
Always On summary says so once, for a week: "This server now uses its own
sandbox setting: open. The settings it had from your computer stay on that
computer."

## Settings after a move

- After a move every Fermix app shows one set of settings, the server's:
  Settings, every pane, changes Fermix on the server, its own sandbox
  (**Sandbox on <server>**), its coding agents (**Allow coding agents to run
  on this server**, under the server's name) and its browser included. A
  new server's sandbox starts `open`. Installing a coding agent there and
  signing it in still take a terminal on the server.
- What belongs to one computer alone sits in one place on it, **This Mac**
  (**This computer** on Linux): what Fermix on the server may use there,
  then its own sandbox, browser (with its Install), screen and history
  (Mac). It changes only at that computer: neither the server
  nor another computer writes it. StackChan is not part of Always On: while
  the home is on the server This Mac shows no StackChan switch, and
  StackChan says "StackChan works again once Fermix is back on this Mac.";
  its setting stays on the Mac as it was for a move back. Removing a computer and `/history off
  <name>` still work from anywhere. The server can be `open` while a Mac
  stays `strict`: each machine's commands run under its own sandbox.
- A stored sandbox variable belongs to the sandbox it is typed in: the
  server's in Settings, the computer's under This Mac.
- A sandbox mode, a provider key, a channel token or a coding approval set
  from an app is stored on the server at once and used from its next start:
  the app offers **Restart <server>** (on a computer, `fermix always-on
  restart-server`), which waits up to ten minutes for work the server runs
  on a computer to end. A computer's own settings take that computer's own
  restart, from its app.
- When the server's sandbox (its mode, command profile or allowed
  variables) or coding approval is changed from a computer, every Always On
  screen says so once, naming the computer; a write that changes nothing
  says nothing. A command Fermix runs can never change a machine's own
  settings through the app.
- A Mac that took the home back keeps its own screen, history and StackChan
  to itself: a computer still linked to it neither lists nor changes them.
- On a linked computer the setup page changes Always On, This computer and
  that computer's sandbox; its other tabs point to the app on any computer.
  `fermix settings show sandbox` there reads the server's, `fermix settings
  show computer.sandbox` its own.
- While the server runs an older Fermix, a computer shows the server's
  sandbox and coding settings nowhere, and its coding agents' check, the
  notetaker's and on-device speech's installers and the Providers pane's
  detection say the server does them only on itself, until the server
  updates on its own; its browser settings are the home's there, shown and
  changed as before.

## Files and commands on a computer

- **Naming the computer.** On an owner's turn, each tool a computer can run
  gains a `computer` argument whose values are the names of the computers
  that offer it, an away one included: `file_read`, `file_write`,
  `file_edit`, `glob_search`, `content_search`, `view_image` and
  `send_attachment` under Files; `shell`, `git_read` and `git_write` under
  Commands. A guest's turn, a worker a skill or a sub-agent runs (a plugin
  skill's above all), a build without Always On and a home with no computer
  offering it never show it, and such a turn naming one is refused as no
  such computer. The owner's scheduled jobs and cues do see it.
- **Where a call runs, never silently:** with no `computer`, on the server
  (it has files and commands of its own); with a name, on that computer.
  A computer that is away is refused at once with when it was last seen
  ("studio Mac is asleep or offline (last seen …), so Fermix cannot reach it
  now. Nothing waits for it to wake."); a name the home has no computer for,
  a computer that does not offer it (switched off, or unavailable, in its
  own words) and a computer too old for this server ("… is used for
  settings only until it updates.") are refused by name. Nothing is sent to
  a computer for a refusal.
- **A path belongs to one machine.** Every result starts "On <name>:", so
  the server's `~/` is never mistaken for a Mac's. Name the computer a path
  is on; never read a server file as if it were that computer's.
- **That computer's sandbox, not the server's.** The call runs the same tool
  code there, held by that computer's own sandbox mode, folders, blocked
  folders and allowed variables, and its kernel sandbox for commands
  (Seatbelt on a Mac, Landlock on Linux). `## Computers` names the folders
  each computer's files and commands reach ("Files and shell on <name> reach
  only ~/Projects … (~ is <name>'s home)"; a path's `~` there is that
  computer's home): ask for one of them, or say plainly that another must be
  allowed at that computer. A path outside them is refused: "<path> is
  outside this computer's sandbox. Files and shell on <name> reach only
  <folders>. Someone at <name> can allow the folder; it cannot be allowed
  from here." `request_directory_access`
  naming a computer asks for nothing: "Folders on <name> are allowed only at
  <name>: someone there adds the folder to its sandbox. Fermix cannot ask for
  it from here." Its settings, secrets, key and journal stay refused, as
  Fermix's own files are here.
- **After outside content** (a web page, a message, a file someone else
  wrote), a command on a Mac runs, its sandbox holding it; every command on
  a Linux computer waits for the owner's confirm in the chat, which names
  the computer ("Confirm shell? It runs a command on loft Linux, which
  Fermix cannot sandbox there."). The confirm is a yes to that one call, not
  a wider sandbox.
- **Bounds are the tools' own:** a read stops at 100 KB, a command's output
  at 1 MiB, an image at 10 MiB, and a file sent from a computer at 20 MiB.
  Large output and files travel in pieces on the link's bulk lane.
- **Sending a file from a computer** (`send_attachment` with `computer`):
  that computer reads it inside its sandbox, the server keeps a copy in its
  workspace (`media/computers/`) and sends it to the chat once.
- **A lost answer.** A read whose answer is lost is read again; a command,
  a write, an edit or a git write is never sent twice, and the reply says
  whether it happened is not known (above).
- A scheduled job that a cue started under a mandate cannot name a
  computer in a file tool: its skill folder is on the server.

## `## Computers` on the owner's turn

- On the server, an owner's turn carries a `## Computers` section right
  after `## This Fermix`, where Always On is offered and the home has at
  least one computer; a guest's turn never does:

  ```
  ## Computers
  - This server: Debian 13. Files, shell and a headless browser run here by default.
  - studio Mac (macOS, connected): files, shell (standard), browser, screen, Messages, history.
  - loft Linux (Linux, away, last seen Sunday, November 8, 2026 at 10:14 PM EST): files, shell (strict), browser.
  ```

- The server comes first, then each computer by name with its system,
  `connected` or `away, last seen <time>` (in the owner's time zone; `not
  connected yet` for one never heard from), and the offers that are on (shell
  with its mode), or `offers nothing`. Never an address or an id. Offers
  that are off or unavailable are not listed; `home.status` keeps why.
- Files and commands on a computer are reached by naming it (above), and
  so is its browser, where the owner's own sign-ins are: `browser` with
  `computer` (skill_view(name: "self-knowledge", file: "browser"), *A
  computer's browser*); without it a turn's browser is the server's own.
  So is its screen: `computer_use` with `computer` (*A computer's screen*),
  never this server's screen as if it were that computer's.
- A computer that is away is asleep or offline: say so and when it was last
  seen, never act as if it was reached, and nothing waits for it to wake.
- What a computer offers changes only at that computer: its **This
  computer** section in the Always On pane (`fermix settings` there on a
  Linux computer without the app). Fermix cannot change it from the server
  or from a chat.

## A computer's screen

- A server with no screen of its own sees and controls the screen of a
  computer that offers it (**Your screen**, `computer_use`, under its
  **This computer** switches): `computer_use` with `computer`, or with no
  name when this server has no screen and exactly one computer offers its
  own. Each step is one action sent to that computer and one image back.
  The session (its action budget, the images it may name, `/pause`,
  `/resume`) stays on the server; the tool's actions and words follow that
  computer's helper (a Linux one may work by controls alone).
- That computer decides for itself: only the owner's own chat or call may
  use its screen (a scheduled run, a cue, a delegated worker or a shared
  channel is refused on the server and again there); its sandbox mode is
  the access level (`strict`: look only; `## Computers` says `screen (look
  only)`); a person typing there holds an action back. One conversation
  holds a screen at a time: another is refused, naming where it is held.
- While the server holds it, that computer shows a mark, "Fermix on your
  server is controlling this screen.", with **Stop** (`home.status`
  `screen`, management `computer.screen.stop`). Stop, or switching **Your
  screen** or everything off there, ends it at once, held keys released,
  and the turn is told the person at that computer stopped it: do not try
  again in that turn; ask. The server holds the screen for as long as its
  session lasts, paused included, renewing its hold every 30 seconds (the
  renewals are not in that computer's record); the computer lets go only
  after two minutes without hearing from it.
- Each stretch the server drove that screen is recorded there
  (`device/screen_control.jsonl`), as is each stretch a server turn held its
  browser (`device/browser_control.jsonl`), and its computer history marks
  events in them as Fermix's own (`by=fermix`), so the summary never reports
  Fermix's clicks or browsing as the owner's. Voice screen sharing (`screen_share`) is this
  server's own screen only.

## Computer history from every computer

- A computer whose recorder is on, with its master switch on, records into
  its own `device/history.db` (raw, 48 hours) and sends each finished sitting to the
  server with `history.submit`; the server makes the note on its summarizer,
  marks it with the computer, and keeps it. Raw text is never written on the
  server, and the summary call's content stays out of its traces and Opik.
  A computer whose summarizer is `local` (its `machine.toml`) sends only the
  note.
- `recall_activity` takes a `computer` and names the machine of each
  sitting; `/history purge` and `/history pause` from chat reach every
  computer (one that is away when next connected); `/history off <name>`
  switches one computer's recorder off from anywhere; and `/history status`
  shows one block per computer with its last report of its recorder.
  Details: `computer_history.md`.

## iMessage through a Mac

- Once the home runs on a server, iMessage goes on through the Mac that
  offers Messages (`imessage`, **Messages** under its **This computer**
  switches): the server runs the listener and the replies, the Mac runs
  Fermix Messages and nothing that makes a turn. The owner texts the same
  Apple ID as before. The helper, its two macOS permissions and the
  confirmed list of who Fermix may message stay on that Mac; the server can
  never change the list (`policy.set` is refused there), only someone at
  the Mac can, on its screen (*Confirm…*). Owner and guests are the home's
  settings (`[fermix_channels.imessage]` in the server's `config.toml`); a
  linked Mac's iMessage settings ask the server for them.
- One home has one Messages bridge: a second Mac that offers Messages is
  refused by name ("loft Mac offers Messages too … refuses loft Mac"), and
  with two offering from the start neither is used until one is switched
  off.
- While that Mac is asleep or offline, iMessage is **away**, not broken: a
  message to the owner fails at once ("the Mac that carries Messages is
  asleep or offline, so the message was not sent, and nothing is kept to
  send later"), and nothing is queued for later. Questions that wait on the
  owner (an approval, a proposal) go to a channel that lives on the server
  first, and never to iMessage while its Mac is away.
- When the Mac's link comes back, Fermix reads what came in meanwhile from
  where it stopped, at most 500 messages from the last 24 hours; if more
  were missed, it tells the owner how many, once, in the chat.
- Photos and files go both ways as bytes, at most 20 MiB each; a larger
  attachment is refused.
- Health and readiness say away (`channel:imessage:away`), name a home with
  no Mac carrying Messages (`channel:imessage:carrier`) or two
  (`channel:imessage:conflict`). Setup: skill_view(name: "self-knowledge",
  file: "channel_setup"), *iMessage*.
