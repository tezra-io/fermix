# Moving back to the computer the home left

Always On's move back: the home comes back from the server to the computer
it left, in place, and afterwards the server is the owner's to turn off or
delete.
The move to a server, the roles and the epoch: skill_view(name:
"self-knowledge", file: "home").

- **Move back.** On the computer the home left, Always On's Details offer
  **Move back to this Mac** ("this computer" off a Mac), beside Back up now.
  It is two presses, each one `home.act`.
  Move back asks the server for a code (it names this desktop, which is how
  the server knows the move goes back and not to another server) and writes
  this computer's candidate for the home beside the moved home
  (`candidate/`, kind `return`) and the move back's record
  (`device/return.json`); this computer's own Fermix then receives beside its
  link ("Connecting this Mac to your server…"). It is refused while the
  server reports a move of its own, and where Fermix runs from a terminal
  ("Fermix runs from a terminal here, so it could not start again on its own
  after the move back. Install it as a service first."). Once the server
  holds it: "This Mac is ready to take Fermix back.", with **Move now**,
  which asks for the server's recovery passphrase, and a confirm built here:
  what runs on this computer again (iMessage, voice calls and meetings, as
  its own settings turn them on), that coding agents ask for approval again,
  that Telegram messages wait, and that the server stays until it is
  deleted. **Cancel** is offered until Move now, and again only once the
  server undid the move or answers with no move at all, never while it
  moves: it stops receiving, closes the code on the server and forgets the
  move back.
- **The move itself.** Move now sends the move to the server, which moves
  the home here as it would to any server and then serves nothing. While
  it runs: "Moving Fermix back to this Mac. Messages wait until it is done."
  (receiving, waiting for the server to hand over, putting Fermix in place).
  The server's copy replaces the retired one in place, this computer's own
  files (logs, browser profiles, iMessage's cursor, the helper apps, models,
  coding runs, the copies of the server's backups) stay
  where they were, the secrets go back into this computer's keychain, its
  own device settings (sandbox, computer use, computer history, iMessage)
  come back from before the move, and Fermix restarts as the primary, one
  epoch up from the server. Phones follow; the desktop link ends. A server
  that undid the move ("The move back was undone. Fermix still runs on your
  server.") offers **Try again** and **Cancel**, also when this computer
  had begun to receive. A move back that ended or stopped part-way is a
  problem (`return_failed`) with **Move back** again, or **Cancel**.
  When another computer took the home back first, this computer's move back
  is dropped quietly.
- **Afterwards.** Back on this computer as the primary, Fermix says so once
  ("Fermix is back on this Mac. Your own server still runs its retired copy:
  turn it off or delete it."); nothing here deletes it. Screen history
  recorded here before the move is not brought back (the server never had
  it).
- **Restore here, when the server is gone.** When nothing answers from the
  server (no answer for 10 minutes, whether it is turned off, deleted or
  unreachable, or no link to it at all; a server that answers, even one that
  no longer knows this computer, is never silent) and this computer keeps a
  copy of its backups, Always On offers **Restore on this Mac** beside the
  problem, with the copy's date. It asks for the recovery passphrase (the
  newest copy that passphrase opens is restored; one that opens none is
  refused before anything is written), and its confirm asks the owner to go
  on only once they deleted the server, or stopped it for good ("if it runs
  again, two copies of Fermix answer the same channels"), and says what is
  lost: messages, memory and jobs since that backup, and Telegram messages
  older than 24 hours. Fermix deletes no server: it restores the copy here
  and restarts as the primary. A restore that stopped before its copy was in
  place is offered again. Before confirming, delete the server, or stop
  Fermix on it for good (or run `fermix home mark-moved` there).
- `fermix always-on move-back` and `fermix always-on restore-here
  --recovery-passphrase-file PATH --yes` take the same steps from a
  terminal; the setup page's Always On tab draws them as any step.
