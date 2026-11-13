# Moving back to the computer the home left

Always On's move back: the home comes back from the server to the computer
it left, in place, and afterwards the server is the owner's to turn off or
delete.
The move to a server, the roles and the epoch: skill_view(name:
"self-knowledge", file: "home").

- **Move back.** On the computer the home left, Always On's Details offer
  **Move back to this Mac** ("this computer" off a Mac), beside Back up now,
  where Fermix starts again by itself: one run from a terminal is not
  offered it, and its Details line Move back says why ("Fermix runs from a
  terminal here, so it could not start again on its own after the move
  back. Install it as a service first.").
  A computer reads a home by the home's format, not by which Fermix wrote
  it: a release raises the format only when it writes something an older
  Fermix cannot read, so a server running a newer Fermix in the same format
  keeps Move back and Restore on this Mac. Where the server's home is in a
  newer format than this computer's Fermix reads, **Update Fermix on this
  Mac first** stands in their place, and the restore itself refuses such a
  backup, writing nothing. Updating the app is the fix: the server only
  takes a release once a published app for each computer keeping its
  backups reads its home, unless its owner went ahead of the apps
  (`fermix-update --release X --ahead-of-apps`).
  It is two presses, each one `home.act`.
  Move back makes this computer's own checks first, so a refused one asks
  the server for nothing, then asks the server for a code (it names this
  desktop, so the server knows the move goes back, not to another server)
  and writes
  this computer's candidate for the home beside the moved home
  (`candidate/`, kind `return`) and the move back's record
  (`device/return.json`); this computer's own Fermix then receives beside its
  link ("Connecting this Mac to your server…"). A step after the code that
  does not go through closes the code on the server again, and its refusal
  says so when the server could not be asked. It is refused while the
  server reports a move of its own, and with the sentence above where
  Fermix runs from a terminal. Once the server
  holds it: "Fermix still runs on your server. It moves back to this Mac
  when you press Move now.", with until when this Mac waits, **Move now**,
  which asks for the server's recovery passphrase, and a confirm from this
  computer's settings: what runs here again (iMessage, voice calls,
  meetings) and that Telegram messages wait, each only where those settings
  have it (not Telegram set up on the server after the move), and that the
  server stays until deleted. Coding agents need nothing again: this Mac
  kept its own approval in its `machine.toml`, in force once it is back. **Cancel** is offered until Move now, and again only once the
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
  own settings (sandbox, computer use, computer history, iMessage, StackChan,
  the dev plugin folder: its `machine.toml`) never left it and stay as they
  were, and Fermix restarts as the primary, one
  epoch up from the server. Phones follow; the desktop link ends, and this
  computer's own key is deleted from its keychain (or file store). A server
  that undid the move ("The move back was undone. Fermix still runs on your
  server.") offers **Try again** and **Cancel**, also when this computer
  had begun to receive. A move back that ended or stopped part-way is a
  problem (`return_failed`) with **Move back** again, or **Cancel**.
  When another computer took the home back first, this one's is dropped
  quietly.
- **Afterwards.** Back on this computer as the primary, Fermix says so once
  ("Fermix is back on this Mac. Your own server still runs its retired copy:
  turn it off or delete it."). Computer history's notes and threads come
  back with the home, those of every computer, and the notes this Mac made
  are "this computer" again; raw history never left this Mac's
  `device/history.db`.
- **Restore here, when the server is gone.** When nothing answers from the
  server (no answer for 10 minutes: turned off, deleted or unreachable, or
  no link at all; a server that answers, even one that
  no longer knows this computer, is never silent) and this computer keeps a
  copy of its backups, Always On offers **Restore on this Mac** beside the
  problem, with the copy's date. It asks for the recovery passphrase (the
  newest copy that passphrase opens is restored; one that opens none is
  refused before anything is written), and its confirm asks the owner to go
  on only once the server is deleted or stopped for good ("if it runs
  again, two copies of Fermix answer the same channels"), and says what is
  lost: messages, memory and jobs since that backup, and Telegram messages
  older than 24 hours where it is set up. Fermix deletes no server: it
  restores the copy here, deletes this computer's own key as a move back
  does, and restarts as the primary. A restore that stopped before its copy was in
  place is offered again. Before confirming, delete the server, or stop
  Fermix on it for good (or run `fermix home mark-moved` there).
- `fermix always-on move-back` and `fermix always-on restore-here
  --recovery-passphrase-file PATH --yes` take the same steps from a
  terminal; the setup page's Always On tab draws them as any step.
