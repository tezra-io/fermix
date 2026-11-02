# Moving back to the computer the home left

Always On's move back: the home comes back from the server to the computer
it left, in place, and afterwards the server is deleted in a step of its own.
The move to a server, the roles and the epoch: skill_view(name:
"self-knowledge", file: "home").

- **Move back.** On the computer the home left, Always On's Details offer
  **Move back to this Mac** ("this computer" off a Mac), beside Back up now
  and Replace the server, whatever server the home moved to: one Fermix
  created or one of the owner's own. It is two presses, each one `home.act`.
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
  coding runs, the provider's file, the copies of the server's backups) stay
  where they were, the secrets go back into this computer's keychain, its
  own device settings (sandbox, computer use, computer history, iMessage)
  come back from before the move, and Fermix restarts as the primary, one
  epoch up from the server. Phones follow; the desktop link ends. A server
  that undid the move ("The move back was undone. Fermix still runs on your
  server.") offers **Try again**. A move back that ended or stopped part-way
  is a problem (`return_failed`) with **Move back** again, or **Cancel**.
  When another computer took the home back first, this computer's move back
  is dropped quietly.
- **Afterwards.** Back on this computer as the primary, while the server
  Fermix created still stands: "Fermix is back on this Mac. Your server
  still runs and costs money until you delete it." with **Delete your
  server**, a separate confirmed step ("Fermix no longer runs on it, and
  everything still on it is gone for good."). A server of the owner's own is
  told once ("Your own server still runs its retired copy: turn it off or
  delete it."); nothing here deletes it. Screen history recorded here before
  the move is not brought back (the server never had it).
- **Restore here, when the server is gone.** When a server Fermix created
  stopped answering (cannot reach it for 10 minutes, turned off, deleted in
  its provider, or no longer connected) and this computer keeps a copy of
  its backups, Always On offers **Restore on this Mac** beside the problem,
  with the copy's date and when the server was last seen. It asks for the
  recovery passphrase (the newest copy that passphrase opens is restored; one
  that opens none is refused before anything is deleted), and its confirm
  says what is lost: messages, memory and jobs since that backup, Telegram
  messages older than 24 hours, and that a server only restarting or offline
  is deleted all the same. Fermix deletes the server first, through the
  provider, then restores the copy here and restarts as the primary; a
  delete the provider refuses restores nothing ("Fermix could not delete
  your server, so it did not restore here: a restored copy beside a running
  server would answer twice."). A server of the owner's own gets no Restore
  here, since nothing here can delete it: stop Fermix on that server (or run
  `fermix home mark-moved` there), then `fermix home import` a copy here.
- `fermix always-on move-back` and `fermix always-on restore-here
  --recovery-passphrase-file PATH --yes` take the same steps from a
  terminal; the setup page's Always On tab draws them as any step.
