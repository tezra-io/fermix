# The home's computers (Always On)

Once the home runs on an Always On server, every computer linked to it is a
member of the home: today the computer the home moved from; a computer that
joins comes in a later update of Fermix. The server keeps a record of each,
and each computer decides for itself what Fermix on the server may use on
it. In this release the server lists its computers and what they offer, but
runs nothing on them yet. The move, the link and the summary: skill_view(name:
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
  `backups`), beside `desktops`, which stays for the apps that read it;
  `fermix home status --json` shows the same. Only the server lists them: on
  a computer `computers` is empty, and `primary` is its link to the server.
- A computer that is away is still listed, with what it last offered and the
  version it last ran, which the server keeps on its own disk.
- **Names.** The owner can rename a computer with the management method
  `computers.rename` (`device_id`, `name`), answered on the server (a
  computer's app forwards it there). A name is one line of at most 64
  characters, and no other computer of the home, nor the server, may already
  have it, compared without case. Its refusals: "Give the computer a name of
  one line, at most 64 characters.", "Another computer of yours is already
  called <name>.", "Your server is already called <name>.", "Your Fermix has
  no such computer." No `fermix` command renames a computer, and the agent
  has no tool for it.

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
| Voice calls (`voice`), Attachments (`attachments`), The robot (`accessory`), Notifications (`notifications`) | calls, attached files, a robot and notifications between that computer and the server | nowhere yet: a later update of Fermix |

Each offer is in one of three states, in the computer's own words when it is
not on ("Mac" reads "computer" off a Mac):

- **on**, commands with their sandbox mode;
- **off**, and why: switched off ("Switched off on this Mac. Only someone at
  this Mac can switch it on."), the master switch off ("Everything Fermix on
  your server may use is switched off on this Mac."), or a review in wait
  ("Waiting for you to review what Fermix on your server may use on this
  Mac.", below);
- **unavailable**, and what is missing: "Messages runs only on a Mac.",
  "Fermix records computer history only on a Mac for now.", "The Fermix
  Computer Use helper is not installed on this Mac.", "This Mac has not
  allowed Fermix Computer Use to see and control the screen.", "Fermix cannot
  see or control the screen on this kind of processor.", "Commands need the
  kernel to hold them to the sandbox, and this computer's kernel does not.",
  and for the four that come later, a sentence that says so ("Calls from
  this computer reach your server in a later update of Fermix.").

A newer computer may offer something this server has no word for; it is
listed as it came.

## Each computer's switches

- What Fermix on the server may use on a computer is that computer's own
  choice: the `[fermix_core.computer]` section of its `machine.toml` (the
  `config` reference): `enabled`, the master switch; `reviewed`; and one
  switch per offer (`files`, `shell`, `browser`, `computer_use`, `imessage`,
  `history`, `voice`, `attachments`, `accessory`, `notifications`). An offer
  is on only while the master is on, its own switch is on and the switches
  are reviewed. An absent offer is off; an absent `enabled` or `reviewed` is
  on, so a computer with no section offers nothing. Each value is `true` or
  `false`; anything else keeps Fermix from starting, naming the key.
- In the app it is the **This computer** settings section of the Always On
  pane, on that computer: **Fermix on your server may use this computer**
  (the master: "Off stops everything Fermix on your server does here, from
  its next request."), **Reviewed**, then **Files**, **Commands**, **The
  browser**, **Your screen**, **Messages**, **Your computer history**,
  **Voice calls**, **Attachments**, **The robot** and **Notifications**. It
  shows only on a computer linked to its server where Always On is offered:
  a computer that never moved has none, and the server has none. On a Linux
  computer without the app, `fermix settings set computer computer_shell=false`
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
with commands on and that computer's sandbox `open`, a server that is
taken over could read and change the account's files there, which is why the
move's review warns of it.

## What a moved computer keeps on

- When the home moves to a server, the computer it leaves keeps what it had:
  files and commands (in the sandbox mode it already has), the browser, and
  the screen, Messages and computer history where their own settings had
  them on (Messages and history on a Mac only). Move now's review shows it as
  a block of its own: a sentence ("After the move, Fermix on your server can
  still use this Mac for: files, commands (standard), the browser, your
  screen. Change this here."), one line per offer, and, where commands stay
  on while the sandbox is `open`, the warning "With commands on and this
  Mac's sandbox open, a server that is taken over can read and change this
  account's files on this Mac." The owner can untick any line before
  starting. The choice is written to that computer's switches when the move
  commits, so a move that is undone leaves none. Voice calls, attachments,
  the robot and notifications are not in the block: they are switched on at
  the computer once they arrive.
- A computer that joins later starts with everything off.
- A computer that moved to its server with an earlier Fermix offers nothing
  until the owner reviews it. At its first start on this Fermix its switches
  are set as a move would have kept them, waiting for the review; Always On
  tells the owner once, as a notification, "Fermix on your server can use
  nothing on this Mac until you review what it may use.", and its Details
  show the block with **Review what your server may use**, which keeps the
  ticked lines on and turns the rest off. The **This computer** section
  finishes the review too: turning **Reviewed** on accepts the switches as
  they are, and changing any switch counts as the review. A review cannot be
  taken back ("A review cannot be taken back. Switch off what Fermix on your
  server may use instead."). From a terminal, on a home the Mac app does not
  manage: `fermix always-on review-offers`.

## The server's own sandbox

An Always On server has its own `machine.toml`. A server whose first start
on this Fermix left out the machine settings it had inherited from the
computer its home came from uses its own sandbox setting, `open`, and its
Always On summary says so once, for a week: "This server now uses its own
sandbox setting: open. The settings it had from your computer stay on that
computer."

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
- In this release Fermix on the server runs nothing on a computer: the
  files, commands and browser a turn uses are the server's own, whatever a
  computer offers. Say so plainly when the owner asks for something on a
  computer, rather than doing it on the server as if it were that computer.
- A computer that is away is asleep or offline: say so and when it was last
  seen, never act as if it was reached, and nothing waits for it to wake.
- What a computer offers changes only at that computer: its **This
  computer** section in the Always On pane (`fermix settings` there on a
  Linux computer without the app). Fermix cannot change it from the server
  or from a chat.
