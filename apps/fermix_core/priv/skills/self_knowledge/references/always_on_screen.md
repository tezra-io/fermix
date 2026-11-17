# The Always On screen, on every surface

The one summary of where Always On stands, which the apps, the setup page
and `fermix home status` draw, and the steps every surface takes through
`home.act`. The roles, the move and the link to the server: skill_view(name:
"self-knowledge", file: "home"); the home's computers: skill_view(name:
"self-knowledge", file: "computers").

## Where each Always On fact and action lives

- Every surface draws one picture, the engine's `home.status`, and acts
  through the same `home.*` methods and settings sections: the Fermix Mac and
  Linux apps' **Always On** pane and the CLI. Nothing on one surface is
  missing from the other except where the table says so.
- **One summary says where Always On stands.** `home.status` carries
  `summary`, the Always On screen, worked out once by the engine, which the
  apps, the setup page and `fermix home status` print as they are: one short
  sentence, at most one more under it (what to check or do, until when
  something waits, why a move was undone, a failure's own words), at most
  one main action (none while a step runs) with every other step beside it,
  Details with facts only, and one help page on the Always On docs for the
  screen. Every action says what the surface must collect first (the
  recovery passphrase), the confirm the owner accepts before Fermix moves,
  restores or forgets (one part per line, never a time that moves with the
  clock; Move now's names every warning of the review, which the screen
  itself never shows), and a key. Its words never name an epoch, the
  primary, a candidate, the relay, the rail, a phase or the daemon, and a
  secret is named as its settings row labels it. Fermix creates, powers and
  deletes no server: the server is the owner's own. Its states:
  - before the move, on the computer that sets it up: nothing set up ("Keep
    Fermix running when this Mac sleeps. It moves to a server you own.",
    **Use my own Linux server**); a code open ("Waiting for your server to
    use its code.", **Replace the code**, **Cancel the code**); the server
    connecting (**Cancel the code**); ready ("Your server is ready. Fermix
    moves to it when you press Move now.", until when it waits under it,
    **Move now**, what this Mac keeps on for its server as ticks, and
    **Forget this server**, which asks first); a review that blocks ("The
    move cannot start yet." with each block, **Check again**); the move
    undone (why, **Try again**, **Forget this server**). Each screen of the
    move, and of the move back, shows its four steps on one line, the
    owner's marked, and while it moves the route to the server and, only
    while bytes move, how much was sent or received;
  - on the computer the move leaves: moving (packing, sending, the server
    unpacking, switching over; "Fermix keeps trying." while it waits on the
    server); "Fermix runs on your server. Last backup 2 hours ago." once
    linked, with **Back up now**, **Add a computer** and **Move back to this
    Mac**, and Details' Backup settings (whether the recovery passphrase is
    set, with **Change**, and that the server keeps an S3 copy where it
    does); no longer connected to it (**Restore on this Mac** where it holds
    a copy, its confirm naming the backup's date); moving back (below);
  - on a computer that joined (no home moved from it): the same while
    linked, without Move back or Restore here; once its server no longer
    knows it, "Your server no longer knows this Mac. To join your Fermix
    again, enter a new code from Add a computer.", with **Join again**,
    which asks for that code masked (the setup page and `fermix always-on
    join` take it, an app once it draws it; the `computers` reference,
    "Removing a computer"); with no link, while it restarts as its own Fermix, "This Mac
    is not connected to a Fermix.";
  - on the server: waiting for its move, then "Fermix runs here."; after a
    move back, its retired copy says "This copy is retired: Fermix moved
    back to <the computer>.";
  - a problem, with the one action that fixes it, or none: no answer for 10
    minutes of this computer being awake (check that it is on and online;
    **Restore on this Mac** where it holds a copy), this computer too old for
    its server or past its window (**Update**), the server older than this
    computer (it updates once the apps carry the newer one) or ahead of the
    apps (**Update**; Move back and Restore here say "Update Fermix on this
    Mac first"), the server's disk 85% full or more (free space or give it a
    bigger disk), the last backup over 3 days old or failed until stored
    (**Back up now**; a failure's own words under it), a move back that
    stopped, and on the server, one that waited past its 24 hours or whose
    enrollment failed (open a new code and run the command there again).
- Details holds facts: the server, its system and version, each place's
  last backup and the S3 bucket, the space this computer's copies take and
  the server's disk, in the owner's time zone as dates and times, never as
  ages. Background and caveats are the Always On docs.
- **What Always On does not do yet**: the apps' "Not with Always On yet" list
  (`summary.detail.not_yet`); what it names and where is in the `computers`
  reference, "What Always On does not do yet".
- **Webhooks on the server.** Slack (Socket Mode), Telegram and Discord need
  nothing inbound. WhatsApp (Meta's Cloud API) and cue webhook sources do,
  and the server opens no public port: they reach it through Tailscale
  Funnel. While Fermix runs on the server, the desktop's Always On screen
  prints the exact command for each mount, to run on the server as root
  (`sudo`: the first boot names no Tailscale operator): WhatsApp's (`sudo
  tailscale funnel --bg --set-path=/webhook/whatsapp
  http://127.0.0.1:<port>/webhook/whatsapp`, the server's web listener port,
  one mount for Meta's GET check and its POSTs, while WhatsApp is on), with
  its note: set the address Tailscale prints as Meta's Callback URL, with
  the verify token, and press Verify and save, for until then WhatsApp
  messages do not arrive; and each enabled webhook source's with a URL,
  its prefix (`/cues/hooks/<ref>` on the server's cue door port, so the
  command carries none of the URL's secret: Tailscale passes the rest of
  the path to the door, which answers only that source's own path), with
  its note: in the sender, change the host of the webhook's address to the
  one Tailscale prints and keep its path. With them: once, in the tailnet
  policy, the `funnel` node attribute for `tag:fermix-server`, and MagicDNS
  and HTTPS certificates on; a new address can take about ten minutes to
  resolve; Funnel publishes whatever `tailscale serve` has on
  port 443, so mount only these paths there; the traffic enters through
  Tailscale's ingress servers, which see only encrypted bytes; without
  Tailscale, Cloudflare Tunnel to the same two loopback ports does the same.
  The ports and the sources are the server's (its `home.status` `webhooks`),
  never this computer's; a server serving none shows nothing, and the
  server's own screen shows none (its desktops do: the server's summary
  rides inside each desktop's `home.status`, where the mounts would pass the
  protocol's nesting bound). Fermix ships no tunnel.
- The summary also names the latest occurrence the apps raise as a system
  notification (`notice`): the server ready, the move done, the server out of
  reach, the last backup a week old, Fermix back on this computer after a
  move back, Restore here finished ("Fermix runs on this Mac again, from its
  backup of <the backup's day>."), and a held server whose 24 hours ran out
  ("Your server waited 24 hours for the move and must be set up again. Open
  a new code in Always On and run the command on it again."). Each keeps one
  id while it stands, so an app posts it once.
- When the server's newest backup passes 7 days it tells the paired phones,
  once per occurrence, as a message in the owner's phone chat: open Fermix on
  the Mac to back up now.
- **No polling.** The apps never ask for the summary on a timer. The chat
  socket tells a connected app that it changed (`home_status_changed`, which
  carries nothing; the app then reads `home.status`): once when the app
  connects unless Always On is off, and whenever the summary's key moves:
  anything a surface draws, the step in hand, a confirm, an alternative, a
  Details line or the notice included, but never the clock alone (a
  backup's age in a sentence). Nothing is told while Always On stays off, not even a settings
  change to what the off line names: the app forgets Always On while it is
  off and reads that line when the pane opens. Fermix works the change out
  without polling: it reads the summary
  again only when something it rests on happens (the move's phase or a move
  back's record, the enrollment code opened, used, withdrawn or expiring, a
  server enrolling, the link to the server up or down, a backup run
  finishing) and at the next time it changes by the clock alone (10 minutes
  awake of silence, a waiting server's 24 hours, a backup's 3 days and its
  7), on one timer, armed again at each read and after a wake from sleep, and
  only while an app is connected. While Always On is off nothing is armed,
  and only a code or a move is read. A
  `home.status` asked with the key it was drawn with and a wait (`after`,
  `wait_ms`, at most 25 seconds) is answered once the key moves, which is how
  a terminal follows a step without polling. After a move the desktop's Fermix tells its app about its own
  summary, reading the server's part again when the server says its own
  moved; while the server is unreachable the chat connection is refused, and
  the app reads the summary then. A server's disk filling is seen at the next
  thing that happens (on the server, every backup run).
- **From a terminal: `fermix always-on`.** On a Homebrew or Linux install
  without the Fermix app, this is how Always On is set up. With no step it
  prints the summary (its sentence and note, the step in hand, Details, the
  help page) and each step with its command; on a terminal it numbers them, Enter takes the main one
  and `q` quits, and for the step taken it asks what the step needs: the
  recovery passphrase without echo (twice where none is set yet), and the
  confirm as `[y/N]`, No unless answered. It prints the step's id as it runs,
  never what was typed, then waits for Always On to move on and offers the
  next step. The code for the server is printed once, under the command
  to run on it. `fermix always-on STEP` takes one step, by the action's id
  with `-` for `_` (`own-server`, `cancel`, `back-up-now`, `check-again`,
  `move-now`, `try-again`, `move-back`, `restore-here`,
  `change-passphrase`, `join`, which asks for the code without echo; `update`
  says how). With no terminal or with `--json` it asks nothing (`join` then
  names `fermix computer join`, which reads the code piped in):
  `--recovery-passphrase-file PATH` gives the passphrase, `--yes` accepts the
  step's confirm, and `--wait` waits; a need no flag gives exits 2 naming the
  flag, and a confirm without `--yes` refuses `confirm_required`. A
  passphrase typed as an argument is refused. The wait asks `home.status` with the screen's key while the
  screen's outcome says Always On is at it, and stops after 45 minutes; a
  waited step that ends on a problem exits 1 (`step_failed`), and so does
  one still at it when the wait runs out (`step_unfinished`), each with the
  screen where it stands, while the screen read alone exits 0 whatever it
  shows. Ctrl-C stops the wait and the step goes on. During Move now the engine restarts, so the wait reconnects for up to
  90 seconds and otherwise says "Start Fermix again to finish the move." If
  Always On changed since the screen was read (another window pressed first),
  it says so (`changed`) and shows the screen again; a Move now sent to the
  server whose answer was lost says so and is followed as a started move;
  any other refusal is the engine's own sentence (`action_refused`). It needs Fermix running
  (`engine_stopped` otherwise, writing nothing), and on a home the Mac app
  manages it refuses `app_managed`, naming the app's Always On pane.
  `fermix home status` ends its summary line with where the next step is
  taken: `fermix always-on`, or the Fermix app on a home the app manages.
- The browser setup page's **Always On** tab is the same screen as the
  apps' pane and takes every step the App column below lists, so an owner
  with no app (a Homebrew or Linux install) sets Always On up there: `fermix
  setup` opens it, over SSH through the tunnel it prints. It draws the
  summary's sentence and note, the step in hand and its buttons; the sentence to
  accept before Fermix moves or restores; the recovery passphrase at **Move
  now** and **Restore on this computer**, typed twice where none is set yet;
  the code for the server, shown once with **Copy**; Details, with
  **Change** for the recovery passphrase; and Learn more. It reads the summary when the
  tab opens and whenever Fermix says it changed, never on a timer, and if
  Always On changed since the screen was drawn a press does nothing and says
  so. **Move now** on the computer that sets it up shows Fermix restarting,
  and the page opens on Always On again once it is back. Inside the Mac app
  the page has no Always On tab: the app's own pane is there.

| Fact or action | App | CLI |
|---|---|---|
| Where Always On stands: one sentence and at most one action (`summary`) | The pane's first line and its button | `fermix home status`, first; `fermix always-on` |
| The role and the epoch | This computer | `fermix home status` |
| On a desktop: the primary (connected or not, since when, its sentence), or where the home moved | The primary | `fermix home status` |
| On the primary: its desktops, each connected or not | Desktops | `fermix home status --json` |
| Whether a recovery passphrase is set; each place snapshots go, its last verified snapshot (and the recovery key it opens with), a desktop copy that is waiting, and its last error | Details: Backup settings | `fermix home snapshots status` |
| Set the recovery passphrase | Backup settings' **Change**: typed twice, never shown; a change says which snapshots open with which passphrase | `fermix home snapshots passphrase` |
| On the primary: the secrets that did not resolve on this host (`secrets_missing`), by id | Secrets to enter again | `fermix home status` |
| How often snapshots run, and whether the recovery passphrase is set (S3 is the server's own) | Recovery: the `snapshots` section | `fermix settings set snapshots …` |
| Take a snapshot now (`home.act` `back_up_now`) | **Back up now**, offered once snapshots have somewhere to go | `fermix always-on back-up-now` |
| An enrollment code for the server (`home.act` `own_server`) | **Use my own Linux server**: the code shown once with **Copy** and when it expires, beside the command for the server, which carries no code, and the optional `--tailscale` one; **Cancel the code** closes it | `fermix always-on own-server`, the code printed once under both commands; `cancel` closes it |
| On a linked desktop: the Tailscale Funnel mounts the server's webhooks need (`summary.detail.webhooks`, from the server's `webhooks`) | Each command with **Copy**, its policy step and caveats | `fermix always-on`, each command on a line of its own |
| What Always On does not do yet for this home (`summary.detail.not_yet`) | Not with Always On yet, a short list | `fermix home status --json` only; the setup page does not show it |
| The servers waiting for the move | Servers waiting for the move | `fermix home candidates` |
| Review the move: each item ready, a note or a block | Move now reviews at the press; **Check again** on a block | The same; `fermix always-on check-again` |
| Start the move (`home.act` `move_now`, `try_again`) | **Move now**, the recovery passphrase asked first | `fermix always-on move-now`, `try-again`: the passphrase asked without echo, or `--recovery-passphrase-file` |
| Where the move stands (its phase and sentence) | The move | `fermix home status` |
| On a linked desktop: the server's own recovery, its move, and the secrets it could not resolve (the composed `primary_home`, or why it is missing) | The server's recovery (**Back up now** asks the server), The server's move | `fermix home status --json` |
| On a linked desktop: move back, or restore from this computer's copy (`home.act` `move_back`, `restore_here`) | **Move back to this Mac**, **Restore on this Mac** | `fermix always-on move-back`, `restore-here` |
| On a computer its server removed: join again with a new code from Add a computer (`home.act` `join`) | **Join again**, the code asked for masked | `fermix always-on join`, or `fermix computer join` with the code piped in |

- In the device role the browser setup page opens on Always On, which acts
  there too, and leads with a notice that Fermix-wide settings live on the
  server and that the page sets up this computer and Always On. Its tabs for providers,
  voice, channels, voice notes, plugins, search, images, coding agents,
  memory, personalization and cues show that sentence instead of their forms;
  its Sandbox and Doctor tabs set up this computer.
