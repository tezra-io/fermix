defmodule FermixCore.Home.Provision.Ledger do
  @moduledoc """
  The provisioner's one file for a provider (M75 lean v1 §4.3):
  `<home>/device/provision/<id>.json`, holding the provider's API token and
  the ledger of what Fermix created there. One file per provider is how the
  ledger records which provider each resource belongs to: a provider's
  resources and its token live in its own file, a token stays with its
  provider, and no file is ever moved or rewritten for another.

  The token lives here and nowhere else: never a `config.toml` reference and
  never the keyring, because a move carries every keyring reference to the
  server and this credential must never go there. `device/` stays on this
  machine (`FermixCore.Home.DeviceLocal`: no archive, snapshot or move takes
  it) and the sandbox denies it to commands on both systems. The file is
  `0600` in a `0700` folder, written whole to a temporary file that is made
  owner-only before anything is written into it, then renamed, so a reader
  never sees half of one and the token is never readable by anyone else.
  The owner can remove it.

      {
        "v": 1,
        "token": "<the API token>",
        "token_state": "accepted",
        "connected_at": "2031-05-04T10:00:00Z",
        "ref": "a3f9",
        "server": {"name": "fermix-general-a3f9", "id": "61839204", "status": "created",
                   "type": "cpx22", "location": "fsn1", "ipv4": "203.0.113.7",
                   "power": "running", "created_at": "...", "seen_at": "...",
                   "total_monthly": "8.33", "currency": "EUR"},
        "firewall": {"name": "fermix-general-a3f9", "id": "1203", "status": "created"},
        "primary_ips": [{"id": "91", "type": "ipv4", "ip": "203.0.113.7"}],
        "failure": {"reason": "resource_unavailable", "sentence": "...",
                    "next_location": "nbg1", "at": "...",
                    "action": "create", "type": "cpx22", "location": "fsn1"},
        "replace": null,
        "action": {"kind": "create", "started_at": "...", "type": "cpx22", "location": "fsn1"},
        "checked_at": "..."
      }

  - `token_state` is `accepted` once the provider accepted the token,
    `refused` once a later call was refused for it (the token stopped
    working).
  - `ref` is the short id (four hex digits) a create mints and every resource
    it makes is named and labelled by, so a lost create is found again by its
    labels; null when nothing was created.
  - A resource's `id` is its provider's own, opaque to Fermix: a string, and
    any other id makes the file malformed. Null until the provider answered
    with one.
  - A resource's `status` is `requested` (written before the call that
    creates it, with no id yet), `creating` (the provider answered with an id
    and its action runs), `created`, `deleting` (written before the call that
    deletes it) or `gone` (deleted outside Fermix). A resource Fermix deleted
    leaves the ledger.
  - A server's `total_monthly` and `currency` are the price of the offer its
    create chose (the server and its IPv4 address, a month, as the account is
    billed), written with the server's first write; null for one created
    before Fermix kept it.
  - `failure` is why the last step stopped, in the daemon's words; null when
    nothing failed. Its `action` is the step (`create`, `delete`,
    `power_on`, `power_reset`; null for one written before Fermix kept it),
    and `type` and `location` the size and place it was for, so a refused
    create keeps them for Create in and Start again.
  - `action` is the step whose job runs now (`Management.Provision`'s
    `put_action/2`, written before the job starts): its `kind` (one of
    `action_kinds/0`), `started_at`, and the `type` and `location` a
    create's job chose (null until it chose); null when no step runs. The
    job's end clears it. One whose job is gone, which a restart leaves, is
    turned into a failure with the reason `interrupted` (`interrupt/3`, at
    boot), and `state/3` reads one older than the job budget
    (`action_budget_ms/0`) the same way, without writing.
  - `checked_at` is when the provider was last read back (a reconcile);
    null until it was.
  - `replace` is a replace of the server (§7 `on` Details "Replace the
    server", run from a linked desktop): null, or `{from_epoch, started_at,
    old, move_started_at, candidate_id, moved_at, deleted_at, failure}`. When
    it begins (`begin_replace/3`) the server the home lives on and what came
    with it (`ref`, `server`, `firewall`, `primary_ips`) are set aside as
    `old`, and the new server is created in the ledger's own places as any
    server is. `from_epoch` is the primary epoch the old server held then;
    `move_started_at` and `candidate_id` are written when this desktop
    started the move to the new server, `moved_at` once it reached a primary
    of a higher epoch (the move to the new one is done, so the old one no
    longer holds the home), `deleted_at` once the old server was deleted, and
    `failure` is why that delete stopped. `old` leaves the ledger with its
    delete; a cancelled replace puts it back in place (`clear/1`).

  The ledger is written before each call that creates or deletes and updated
  after it (`update/3`). Updates are serialised per file: `Ledger.Lock`, the
  one owner of the locks, holds a file's lock across the read, the change,
  the write and the rename (never across a call to the provider) and serves
  writers in the order they asked, so two writers never lose each other's
  change and none waits while the file is free.

  `state/1` is what `home.status`'s summary reads: one of `none`,
  `connected`, `creating`, `created` (the server exists and waits for its
  enrollment and move, which the summary reads elsewhere), `deleting`,
  `gone`, `failed` (with the failure, whatever else the ledger holds) and
  `unreadable`, beside whether the token is accepted, the server's facts, the
  step that runs and when the provider was last read back. It never answers
  the token.

  While a replace is recorded, `state/1`'s `replace` says where it stands,
  and `state` and `server` are the new server's:

    * `creating`: the new server is being created (or its create was asked
      for and nothing stands yet); the old one holds the home.
    * `waiting`: the new server exists and waits for its enrollment and its
      move, which the owner starts.
    * `moving`: this desktop started the move to the new server; the old one
      serves nothing while it runs, so nothing else is known until the move
      is done or undone (a move the old server undid shows in its own
      `home.status` once it answers again, `move.phase` `aborted`, and this
      state then goes back to `waiting`).
    * `deleting`: the move is done (this desktop reached the server at a
      higher epoch than the old one held), and the old server is being
      deleted, once.
    * `done`: the old server is deleted; the new one holds the home.
    * `failed`: with `failure`, why: the new server's create stopped, or the
      new server was deleted at the provider (`reason` `gone`), and the old one
      still holds the home (`current` `old`); or deleting the old server
      stopped (`current` `new`), which leaves it listed for the owner to
      delete.
    * `cancelling`: the new server is being deleted before the move (Cancel,
      Start again); the old one keeps the home.

  `current` says which server holds the home: `old` until the move is done,
  then `new`; `old` is the old server's facts, null once it is deleted.
  """

  alias FermixCore.Home.Provision
  alias FermixCore.Home.Provision.Ledger.Lock
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Home.UnreadableFiles
  alias FermixCore.Management.Jobs

  @version 1
  @dir_mode 0o700
  @file_mode 0o600
  @statuses ~w(requested creating created deleting gone)a
  @status_words Map.new(@statuses, &{Atom.to_string(&1), &1})
  @action_kinds ~w(create delete power_on power_reset)
  # The failures a token's own refusal leaves.
  @token_reasons ~w(read_only_token token_refused)
  # What a failure keeps beside its reason; null for one written before it.
  @failure_step %{action: nil, type: nil, location: nil}

  @type status :: :requested | :creating | :created | :deleting | :gone
  @type server :: %{
          name: String.t(),
          id: String.t() | nil,
          status: status(),
          type: String.t(),
          location: String.t(),
          ipv4: String.t() | nil,
          power: String.t() | nil,
          created_at: DateTime.t() | nil,
          seen_at: DateTime.t() | nil,
          total_monthly: String.t() | nil,
          currency: String.t() | nil
        }
  @type firewall :: %{name: String.t(), id: String.t() | nil, status: status()}
  @type primary_ip :: %{id: String.t(), type: String.t(), ip: String.t() | nil}
  @type failure :: %{
          reason: String.t(),
          sentence: String.t(),
          next_location: String.t() | nil,
          at: DateTime.t(),
          action: String.t() | nil,
          type: String.t() | nil,
          location: String.t() | nil
        }
  @type action :: %{
          kind: String.t(),
          started_at: DateTime.t(),
          type: String.t() | nil,
          location: String.t() | nil
        }
  @typedoc "One server and what came with it: the ledger's own places, or a replace's `old`."
  @type set :: %{
          ref: String.t() | nil,
          server: server() | nil,
          firewall: firewall() | nil,
          primary_ips: [primary_ip()]
        }
  @type replace :: %{
          from_epoch: pos_integer(),
          started_at: DateTime.t(),
          old: set() | nil,
          move_started_at: DateTime.t() | nil,
          candidate_id: String.t() | nil,
          moved_at: DateTime.t() | nil,
          deleted_at: DateTime.t() | nil,
          failure: failure() | nil
        }
  @type t :: %{
          token: String.t() | nil,
          token_state: :accepted | :refused | nil,
          connected_at: DateTime.t() | nil,
          ref: String.t() | nil,
          server: server() | nil,
          firewall: firewall() | nil,
          primary_ips: [primary_ip()],
          failure: failure() | nil,
          replace: replace() | nil,
          action: action() | nil,
          checked_at: DateTime.t() | nil
        }
  @type replace_state ::
          :creating | :waiting | :moving | :deleting | :done | :failed | :cancelling
  @type replace_view :: %{
          state: replace_state(),
          current: :old | :new,
          old: server() | nil,
          failure: failure() | nil
        }
  @type state_view :: %{
          state:
            :none | :connected | :creating | :created | :deleting | :gone | :failed | :unreadable,
          token: :none | :accepted | :refused,
          server: map() | nil,
          failure: failure() | nil,
          sentence: String.t() | nil,
          replace: replace_view() | nil,
          action: action() | nil,
          checked_at: DateTime.t() | nil
        }

  @doc "The kinds of step a ledger's `action` names, ordered."
  @spec action_kinds() :: [String.t()]
  def action_kinds, do: @action_kinds

  @doc """
  How long a step's action stands before it is read as interrupted: the
  budget of the job it names (`Management.Jobs`, `home_provision`).
  """
  @spec action_budget_ms() :: pos_integer()
  def action_budget_ms, do: Jobs.budget_ms(:home_provision)

  @doc "Where the file of the provider `id` lives under `home`."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(home, id) when is_binary(home) and home != "" and is_binary(id),
    do: Path.join([home, "device", "provision", id <> ".json"])

  @doc "A ledger with nothing in it: no token, nothing created."
  @spec empty() :: t()
  def empty do
    %{
      token: nil,
      token_state: nil,
      connected_at: nil,
      ref: nil,
      server: nil,
      firewall: nil,
      primary_ips: [],
      failure: nil,
      replace: nil,
      action: nil,
      checked_at: nil
    }
  end

  @doc "The ledger of the provider `id`: an empty one when the file is absent."
  @spec read(Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def read(home, id) when is_binary(home) and is_binary(id) do
    file = path(home, id)

    case File.read(file) do
      {:ok, json} -> decode(json, file)
      {:error, :enoent} -> {:ok, empty()}
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  @doc """
  Reads the ledger, hands it to `fun`, and writes what `fun` answers
  (`{:ok, ledger}`), all under the file's lock (`Ledger.Lock`, released on
  every path); `{:error, _}` from `fun` is answered as it is and writes
  nothing. `{:error, {:locked, file}}` when the lock did not come within its
  bound. This is the one write of every provider's ledger (the driver's and
  the management family's), so it is where the Always On watch
  (`Home.StatusWatch`) is told, since the summary reads this file.
  """
  @spec update(Path.t(), String.t(), (t() -> {:ok, t()} | {:error, term()})) ::
          {:ok, t()} | {:error, term()}
  def update(home, id, fun) when is_binary(home) and is_binary(id) and is_function(fun, 1) do
    file = path(home, id)

    with :ok <- Lock.acquire(file) do
      try do
        read_apply_write(home, id, fun)
      after
        :ok = Lock.release(file)
      end
    end
  end

  defp read_apply_write(home, id, fun) do
    with {:ok, ledger} <- read(home, id),
         {:ok, changed} <- fun.(ledger),
         :ok <- write(path(home, id), changed) do
      :ok = StatusWatch.changed(:ledger)
      {:ok, changed}
    end
  end

  @doc """
  Whether the ledger holds anything Fermix created or was creating (a short
  id, a server, a firewall, an address) or a replace: what makes its
  provider the one Always On speaks of (`Provision.current/2`).
  """
  @spec holding?(t()) :: boolean()
  def holding?(%{ref: nil, server: nil, firewall: nil, primary_ips: [], replace: nil}), do: false
  def holding?(%{} = _ledger), do: true

  # -- the transforms the provisioner writes through `update/3` ---------------

  @doc "The token the provider just accepted, with when."
  @spec connect(t(), String.t(), DateTime.t()) :: t()
  def connect(ledger, token, %DateTime{} = now) when is_binary(token) and token != "",
    do: %{ledger | token: token, token_state: :accepted, connected_at: now}

  @doc """
  A token was accepted in place of one whose refusal stopped a create
  (`read_only_token`, `token_refused`; review R1): that failure no longer
  says what is wrong. A create that made nothing but its short id leaves
  the ledger as it was before it, so the next screen offers the create; one
  that left something standing (or stopped a replace) keeps its failure as
  `token_replaced`, in `provider`'s words, so the next screen offers it
  again. Any other failure, and everything Fermix created, stays.
  """
  @spec token_replaced(t(), module()) :: t()
  def token_replaced(%{failure: %{reason: reason, action: action}} = ledger, provider)
      when reason in @token_reasons and action in ["create", nil] and is_atom(provider) do
    if made_nothing?(ledger),
      do: %{ledger | failure: nil, ref: nil},
      else: %{ledger | failure: replaced_failure(ledger.failure, provider)}
  end

  def token_replaced(ledger, provider) when is_atom(provider), do: ledger

  defp made_nothing?(ledger),
    do: match?(%{server: nil, firewall: nil, primary_ips: [], replace: nil}, ledger)

  defp replaced_failure(failure, provider),
    do: %{
      failure
      | reason: "token_replaced",
        sentence: Provision.error_sentence(:token_replaced, provider)
    }

  @doc "The provider refused a call for the token it accepted before."
  @spec token_refused(t()) :: t()
  def token_refused(%{token: token} = ledger) when is_binary(token),
    do: %{ledger | token_state: :refused}

  @doc """
  A create begins under the short id `ref`: the last failure is dropped and
  the firewall, named for the server, is `requested`.
  """
  @spec begin_create(t(), String.t(), %{name: String.t()}) :: t()
  def begin_create(ledger, ref, %{name: name}) when is_binary(ref) and is_binary(name) do
    %{
      ledger
      | ref: ref,
        failure: nil,
        server: nil,
        firewall: %{name: name, id: nil, status: :requested},
        primary_ips: []
    }
  end

  @doc """
  Merges `attrs` into the server (one is made from them when there is none),
  of the ledger or of the server a replace set aside.
  """
  @spec put_server(t() | set(), map()) :: t() | set()
  def put_server(ledger, attrs) when is_map(attrs) do
    blank = %{
      id: nil,
      ipv4: nil,
      power: nil,
      created_at: nil,
      seen_at: nil,
      total_monthly: nil,
      currency: nil
    }

    %{ledger | server: blank |> Map.merge(ledger.server || %{}) |> Map.merge(attrs)}
  end

  @doc "Merges `attrs` into the firewall (one is made from them when there is none)."
  @spec put_firewall(t() | set(), map()) :: t() | set()
  def put_firewall(ledger, attrs) when is_map(attrs),
    do: %{ledger | firewall: %{id: nil} |> Map.merge(ledger.firewall || %{}) |> Map.merge(attrs)}

  @doc "The primary addresses the server was given."
  @spec put_primary_ips(t(), [primary_ip()]) :: t()
  def put_primary_ips(ledger, ips) when is_list(ips), do: %{ledger | primary_ips: ips}

  @doc """
  Why the last step stopped, or nil; a failure given without its step
  (`action`, `type`, `location`) is kept with none.
  """
  @spec put_failure(t(), map() | nil) :: t()
  def put_failure(ledger, failure) when is_map(failure) or is_nil(failure),
    do: %{ledger | failure: with_step(failure)}

  defp with_step(nil), do: nil
  defp with_step(failure), do: Map.merge(@failure_step, failure)

  @doc """
  A step's job is about to start: `kind` (one of `action_kinds/0`) from
  `now`. Refused `:busy` while another step's action stands inside the job
  budget; one older than it is an interrupted step's, which this one takes
  over.
  """
  @spec put_action(t(), String.t(), DateTime.t()) :: {:ok, t()} | {:error, :busy}
  def put_action(ledger, kind, %DateTime{} = now) when kind in @action_kinds do
    if live_action?(ledger.action, now),
      do: {:error, :busy},
      else: {:ok, %{ledger | action: %{kind: kind, started_at: now, type: nil, location: nil}}}
  end

  @doc "The size and place a create's job chose, kept on its action; unchanged with none."
  @spec choose(t(), %{type: String.t(), location: String.t()}) :: t()
  def choose(%{action: %{} = action} = ledger, %{type: type, location: location})
      when is_binary(type) and is_binary(location),
      do: %{ledger | action: %{action | type: type, location: location}}

  def choose(%{action: nil} = ledger, %{type: _type, location: _location}), do: ledger

  @doc """
  The step's job ended with `failure`, in its run's words: it is kept with
  the step's server's size and place where it names none, and the action
  goes, in one write (`Management.Provision`'s ending).
  """
  @spec end_step(t(), map()) :: t()
  def end_step(ledger, %{reason: reason, sentence: sentence} = failure)
      when is_binary(reason) and is_binary(sentence) do
    server = %{
      type: ledger.server && ledger.server.type,
      location: ledger.server && ledger.server.location
    }

    %{ledger | action: nil, failure: with_step(Map.merge(server, failure))}
  end

  @doc "The step's job ended: its action goes; `:no_action` when none stood."
  @spec clear_action(t()) :: {:ok, t()} | {:error, :no_action}
  def clear_action(%{action: nil}), do: {:error, :no_action}
  def clear_action(ledger), do: {:ok, %{ledger | action: nil}}

  @doc """
  The step's job is gone without ending it (a restart, a job outliving its
  budget): its action becomes the failure `interrupted`, in `provider`'s
  sentence for that step, at `at`, keeping the step and its size and place.
  `:no_action` when none stood.
  """
  @spec interrupt(t(), module(), DateTime.t()) :: {:ok, t()} | {:error, :no_action}
  def interrupt(%{action: nil}, _provider, _at), do: {:error, :no_action}

  def interrupt(%{action: action} = ledger, provider, %DateTime{} = at) when is_atom(provider) do
    failure = %{
      reason: "interrupted",
      sentence: Provision.error_sentence({:interrupted, action.kind}, provider),
      next_location: nil,
      at: at,
      action: action.kind,
      type: action.type,
      location: action.location
    }

    {:ok, %{ledger | action: nil, failure: failure}}
  end

  @doc "The provider was read back at `now`."
  @spec checked(t(), DateTime.t()) :: t()
  def checked(ledger, %DateTime{} = now), do: %{ledger | checked_at: now}

  defp live_action?(nil, _now), do: false

  defp live_action?(%{started_at: started_at}, now),
    do: DateTime.diff(now, started_at, :millisecond) < action_budget_ms()

  @doc "Removes a resource Fermix deleted (`:server` or `:firewall`)."
  @spec remove(t() | set(), :server | :firewall) :: t() | set()
  def remove(ledger, kind) when kind in [:server, :firewall], do: Map.put(ledger, kind, nil)

  @doc """
  Everything Fermix created is deleted: the token stays. A replace whose
  move was not done ends with it, and the server it would have replaced is
  the ledger's own again.
  """
  @spec clear(t()) :: t()
  def clear(%{replace: %{old: %{} = old, moved_at: nil}} = ledger),
    do: Map.merge(%{ledger | failure: nil, replace: nil}, old)

  def clear(ledger),
    do: %{
      ledger
      | ref: nil,
        server: nil,
        firewall: nil,
        primary_ips: [],
        failure: nil,
        replace: nil
    }

  # -- a replace ----------------------------------------------------------------

  @doc """
  Whether a replace of the server may begin (`:begin`: no replace is under
  way, and the server the home lives on stands), goes on with the new server
  it has not created yet (`:continue`), or why not: `:replacement_exists`
  (the new one stands), `:replace_moving`, `:old_server_remains` (the move is
  done and the old server is not deleted yet), `:not_primary` (the ledger
  holds no server the home could live on).
  """
  @spec replacing(t()) :: :begin | :continue | {:error, atom()}
  def replacing(%{replace: nil} = ledger), do: standing_server(ledger)
  def replacing(%{replace: %{deleted_at: %DateTime{}}} = ledger), do: standing_server(ledger)
  def replacing(%{replace: %{moved_at: %DateTime{}}}), do: {:error, :old_server_remains}
  def replacing(%{replace: %{move_started_at: %DateTime{}}}), do: {:error, :replace_moving}

  def replacing(%{server: %{status: status}}) when status != :gone,
    do: {:error, :replacement_exists}

  def replacing(_ledger), do: :continue

  defp standing_server(%{server: %{status: :created}}), do: :begin
  defp standing_server(_ledger), do: {:error, :not_primary}

  @doc """
  Begins a replace (`replacing/1` says whether it may): the server the home
  lives on, held at primary epoch `from_epoch`, and what came with it are set
  aside as `old`, and the ledger's own places are free for the new server.
  One that goes on is answered as it is.
  """
  @spec begin_replace(t(), pos_integer(), DateTime.t()) :: {:ok, t()} | {:error, atom()}
  def begin_replace(ledger, from_epoch, %DateTime{} = now)
      when is_integer(from_epoch) and from_epoch > 0 do
    case replacing(ledger) do
      :begin -> {:ok, set_aside(ledger, from_epoch, now)}
      :continue -> {:ok, ledger}
      {:error, _reason} = error -> error
    end
  end

  defp set_aside(ledger, from_epoch, now) do
    replace = %{
      from_epoch: from_epoch,
      started_at: now,
      old: Map.take(ledger, [:ref, :server, :firewall, :primary_ips]),
      move_started_at: nil,
      candidate_id: nil,
      moved_at: nil,
      deleted_at: nil,
      failure: nil
    }

    %{
      ledger
      | ref: nil,
        server: nil,
        firewall: nil,
        primary_ips: [],
        failure: nil,
        replace: replace
    }
  end

  @doc "The short id of the server a replace set aside, so the new one never takes it; or nil."
  @spec replaced_ref(t()) :: String.t() | nil
  def replaced_ref(%{replace: %{old: %{ref: ref}}}), do: ref
  def replaced_ref(_ledger), do: nil

  @doc "The server a replace set aside, with what came with it; nil when there is none."
  @spec replaced_set(t()) :: set() | nil
  def replaced_set(%{replace: %{old: old}}), do: old
  def replaced_set(_ledger), do: nil

  @doc "Writes `set` in place of the server a replace set aside."
  @spec put_replaced_set(t(), set()) :: t()
  def put_replaced_set(%{replace: %{old: %{}} = replace} = ledger, %{} = set),
    do: %{ledger | replace: %{replace | old: set}}

  @doc """
  The server a replace retired, once the move to the new one is done: never
  the one that still holds the home (`:live_home`), and `:nothing_to_delete`
  when no replace holds one.
  """
  @spec retired(t()) :: {:ok, set()} | {:error, :live_home | :nothing_to_delete}
  def retired(%{replace: %{moved_at: %DateTime{}, old: %{} = old}}), do: {:ok, old}
  def retired(%{replace: %{moved_at: nil, old: %{}}}), do: {:error, :live_home}
  def retired(_ledger), do: {:error, :nothing_to_delete}

  @doc """
  This desktop started the move to the new server, a candidate of the server
  being replaced: `:not_replacing` when no replace waits for its move.
  """
  @spec move_started(t(), String.t(), DateTime.t()) :: {:ok, t()} | {:error, :not_replacing}
  def move_started(
        %{replace: %{old: %{}, moved_at: nil} = replace} = ledger,
        candidate_id,
        %DateTime{} = now
      )
      when is_binary(candidate_id),
      do:
        {:ok, %{ledger | replace: %{replace | move_started_at: now, candidate_id: candidate_id}}}

  def move_started(_ledger, _candidate_id, _now), do: {:error, :not_replacing}

  @doc """
  What this desktop reaching its server at primary epoch `epoch` means for a
  replace: `:clean_up` once the epoch is above the one the old server held
  (the move to the new one is done, and the old server, not deleted yet and
  with no failed delete, is deleted now); `:undone` when the old server
  answers again at its own epoch after the move started (it undid the move);
  otherwise `:none`.
  """
  @spec replace_due(t(), pos_integer()) :: :clean_up | :undone | :none
  def replace_due(%{replace: %{old: %{}, deleted_at: nil, failure: nil} = replace}, epoch)
      when is_integer(epoch) do
    cond do
      epoch > replace.from_epoch -> :clean_up
      epoch == replace.from_epoch and moving?(replace) -> :undone
      true -> :none
    end
  end

  def replace_due(_ledger, _epoch), do: :none

  defp moving?(replace), do: replace.move_started_at != nil and replace.moved_at == nil

  @doc """
  The move to the new server is done: this desktop reached a primary of
  `epoch`, above the old server's. The first time is kept.
  """
  @spec moved(t(), pos_integer(), DateTime.t()) :: {:ok, t()} | {:error, :not_moved}
  def moved(
        %{replace: %{old: %{}, deleted_at: nil, failure: nil} = replace} = ledger,
        epoch,
        %DateTime{} = now
      )
      when is_integer(epoch) and epoch > replace.from_epoch,
      do: {:ok, %{ledger | replace: %{replace | moved_at: replace.moved_at || now}}}

  def moved(_ledger, _epoch, _now), do: {:error, :not_moved}

  @doc "The old server undid the move: the replace waits for the owner again."
  @spec move_undone(t()) :: {:ok, t()} | {:error, :not_replacing}
  def move_undone(%{replace: %{moved_at: nil, move_started_at: %DateTime{}} = replace} = ledger),
    do: {:ok, %{ledger | replace: %{replace | move_started_at: nil, candidate_id: nil}}}

  def move_undone(_ledger), do: {:error, :not_replacing}

  @doc "The old server is deleted: the replace is done."
  @spec replaced_deleted(t(), DateTime.t()) :: t()
  def replaced_deleted(%{replace: %{} = replace} = ledger, %DateTime{} = now),
    do: %{ledger | replace: %{replace | old: nil, deleted_at: now, failure: nil}}

  @doc "Why deleting the old server stopped, or nil when it is tried again."
  @spec put_replace_failure(t(), failure() | nil) :: t()
  def put_replace_failure(%{replace: %{} = replace} = ledger, failure)
      when is_map(failure) or is_nil(failure),
      do: %{ledger | replace: %{replace | failure: with_step(failure)}}

  # -- the summary --------------------------------------------------------------

  @doc """
  What the summary reads of `provider`'s ledger (a module of the
  `Home.Provision` contract): the state, whether the token is accepted, the
  server's facts, the last failure in the provider's words, the step that
  runs and when the provider was last read back. An unreadable file is
  answered `unreadable` with its sentence on every read, and logged once
  when it stops being readable and once when it reads again
  (`Home.UnreadableFiles`, `opts`' `:unreadable_files`: that memory, or nil
  for none), since `home.status` is polled. A step's action older than the
  job budget at `opts`' `:now` (the clock by default) reads as the failure
  `interrupt/3` would write, due when the budget ran out; nothing is
  written.
  """
  @spec state(Path.t(), module(), keyword()) :: state_view()
  def state(home, provider, opts \\ [])
      when is_binary(home) and is_atom(provider) and is_list(opts) do
    read = read(home, provider.id())
    memory = Keyword.get(opts, :unreadable_files, UnreadableFiles)
    :ok = UnreadableFiles.log_read(path(home, provider.id()), "provision", read, memory)

    case read do
      {:ok, ledger} ->
        now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
        ledger |> settled(provider, now) |> state_view(provider)

      {:error, _reason} ->
        %{
          state: :unreadable,
          token: :none,
          server: nil,
          failure: nil,
          sentence: Provision.error_sentence(:unreadable, provider),
          replace: nil,
          action: nil,
          checked_at: nil
        }
    end
  end

  defp state_view(ledger, provider) do
    %{
      state: derive(ledger),
      token: token_word(ledger),
      server: ledger.server,
      failure: ledger.failure,
      sentence: nil,
      replace: replace_view(ledger, provider),
      action: ledger.action,
      checked_at: ledger.checked_at
    }
  end

  # An action its job outlived is read as the interruption it is.
  defp settled(%{action: %{started_at: started_at} = action} = ledger, provider, now) do
    if live_action?(action, now) do
      ledger
    else
      due = DateTime.add(started_at, action_budget_ms(), :millisecond)
      {:ok, interrupted} = interrupt(ledger, provider, due)
      interrupted
    end
  end

  defp settled(ledger, _provider, _now), do: ledger

  defp replace_view(%{replace: nil}, _provider), do: nil

  defp replace_view(%{replace: replace} = ledger, provider) do
    {state, failure} = replace_state(ledger, provider)

    %{
      state: state,
      current: if(replace.moved_at, do: :new, else: :old),
      old: replace.old && replace.old.server,
      failure: failure
    }
  end

  defp replace_state(%{replace: replace} = ledger, provider) do
    cond do
      replace.failure != nil -> {:failed, replace.failure}
      replace.deleted_at != nil -> {:done, nil}
      replace.moved_at != nil -> {:deleting, nil}
      replace.move_started_at != nil -> {:moving, nil}
      true -> before_move(ledger, provider)
    end
  end

  # Before the move the new server's own places say where the replace is; a
  # failure first, a delete it stopped included.
  defp before_move(ledger, provider) do
    cond do
      ledger.failure != nil -> {:failed, ledger.failure}
      deleting?(ledger) -> {:cancelling, nil}
      match?(%{status: :gone}, ledger.server) -> {:failed, gone(ledger.server, provider)}
      match?(%{status: :created}, ledger.server) -> {:waiting, nil}
      true -> {:creating, nil}
    end
  end

  # The new server deleted at the provider before the move: the replace
  # starts again.
  defp gone(server, provider) do
    with_step(%{
      reason: "gone",
      sentence: Provision.error_sentence(:replacement_gone, provider),
      next_location: nil,
      at: server.seen_at || server.created_at
    })
  end

  defp derive(%{token: nil}), do: :none

  # A failure first: a delete that stopped leaves something deleting.
  defp derive(ledger) do
    cond do
      ledger.failure != nil -> :failed
      deleting?(ledger) -> :deleting
      creating?(ledger) -> :creating
      match?(%{status: :created}, ledger.server) -> :created
      match?(%{status: :gone}, ledger.server) -> :gone
      true -> :connected
    end
  end

  defp deleting?(ledger),
    do: Enum.any?([ledger.server, ledger.firewall], &match?(%{status: :deleting}, &1))

  defp creating?(%{ref: nil}), do: false
  defp creating?(%{server: nil}), do: true
  defp creating?(%{server: %{status: status}}), do: status in [:requested, :creating]

  defp token_word(%{token: nil}), do: :none
  defp token_word(%{token_state: :refused}), do: :refused
  defp token_word(_ledger), do: :accepted

  # -- the file ---------------------------------------------------------------

  defp write(file, ledger) do
    tmp = file <> ".tmp"

    with :ok <- mkdir_private(Path.dirname(file)),
         :ok <- write_private(tmp, Jason.encode!(encode(ledger))),
         :ok <- rename(tmp, file) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp mkdir_private(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(Path.dirname(dir), @dir_mode),
         :ok <- File.chmod(dir, @dir_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:file, dir, reason}}
    end
  end

  # Owner-only before the token is written into it.
  defp write_private(tmp, contents) do
    _ = File.rm(tmp)

    case File.open(tmp, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        result = chmod_and_write(io, tmp, contents)
        :ok = File.close(io)
        result

      {:error, reason} ->
        {:error, {:file, tmp, reason}}
    end
  end

  defp chmod_and_write(io, tmp, contents) do
    with :ok <- File.chmod(tmp, @file_mode),
         :ok <- IO.binwrite(io, contents) do
      :ok
    else
      {:error, reason} -> {:error, {:file, tmp, reason}}
    end
  end

  defp rename(tmp, file) do
    case File.rename(tmp, file) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp encode(ledger) do
    %{
      "v" => @version,
      "token" => ledger.token,
      "token_state" => ledger.token_state && Atom.to_string(ledger.token_state),
      "connected_at" => iso(ledger.connected_at),
      "ref" => ledger.ref,
      "server" => ledger.server && encode_server(ledger.server),
      "firewall" => ledger.firewall && encode_firewall(ledger.firewall),
      "primary_ips" => Enum.map(ledger.primary_ips, &encode_ip/1),
      "failure" => ledger.failure && encode_failure(ledger.failure),
      "replace" => ledger.replace && encode_replace(ledger.replace),
      "action" => ledger.action && encode_action(ledger.action),
      "checked_at" => iso(ledger.checked_at)
    }
  end

  defp encode_action(action) do
    %{
      "kind" => action.kind,
      "started_at" => iso(action.started_at),
      "type" => action.type,
      "location" => action.location
    }
  end

  defp encode_replace(replace) do
    %{
      "from_epoch" => replace.from_epoch,
      "started_at" => iso(replace.started_at),
      "old" => replace.old && encode_set(replace.old),
      "move_started_at" => iso(replace.move_started_at),
      "candidate_id" => replace.candidate_id,
      "moved_at" => iso(replace.moved_at),
      "deleted_at" => iso(replace.deleted_at),
      "failure" => replace.failure && encode_failure(replace.failure)
    }
  end

  defp encode_set(set) do
    %{
      "ref" => set.ref,
      "server" => set.server && encode_server(set.server),
      "firewall" => set.firewall && encode_firewall(set.firewall),
      "primary_ips" => Enum.map(set.primary_ips, &encode_ip/1)
    }
  end

  defp encode_server(server) do
    %{
      "name" => server.name,
      "id" => server.id,
      "status" => Atom.to_string(server.status),
      "type" => server.type,
      "location" => server.location,
      "ipv4" => server.ipv4,
      "power" => server.power,
      "created_at" => iso(server.created_at),
      "seen_at" => iso(server.seen_at),
      "total_monthly" => server.total_monthly,
      "currency" => server.currency
    }
  end

  defp encode_firewall(firewall),
    do: %{
      "name" => firewall.name,
      "id" => firewall.id,
      "status" => Atom.to_string(firewall.status)
    }

  defp encode_ip(ip), do: %{"id" => ip.id, "type" => ip.type, "ip" => ip.ip}

  defp encode_failure(failure) do
    %{
      "reason" => failure.reason,
      "sentence" => failure.sentence,
      "next_location" => failure.next_location,
      "at" => iso(failure.at),
      "action" => failure.action,
      "type" => failure.type,
      "location" => failure.location
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp decode(json, file) do
    with {:ok, %{"v" => @version} = map} <- Jason.decode(json),
         {:ok, ledger} <- decode_map(map) do
      {:ok, ledger}
    else
      _invalid -> {:error, {:invalid_ledger, file}}
    end
  end

  defp decode_map(map) do
    with {:ok, token} <- optional_text(map["token"]),
         {:ok, token_state} <- optional_word(map["token_state"], ~w(accepted refused)),
         {:ok, connected_at} <- optional_time(map["connected_at"]),
         {:ok, ref} <- optional_text(map["ref"]),
         {:ok, server} <- optional(map["server"], &decode_server/1),
         {:ok, firewall} <- optional(map["firewall"], &decode_firewall/1),
         {:ok, ips} <- decode_ips(map["primary_ips"]),
         {:ok, failure} <- optional(map["failure"], &decode_failure/1),
         {:ok, replace} <- optional(map["replace"], &decode_replace/1),
         {:ok, action} <- optional(map["action"], &decode_action/1),
         {:ok, checked_at} <- optional_time(map["checked_at"]) do
      {:ok,
       %{
         token: token,
         token_state: token_state,
         connected_at: connected_at,
         ref: ref,
         server: server,
         firewall: firewall,
         primary_ips: ips,
         failure: failure,
         replace: replace,
         action: action,
         checked_at: checked_at
       }}
    end
  end

  defp decode_action(%{"kind" => kind} = map) when kind in @action_kinds do
    with {:ok, %DateTime{} = started_at} <- optional_time(map["started_at"]),
         {:ok, type} <- optional_text(map["type"]),
         {:ok, location} <- optional_text(map["location"]) do
      {:ok, %{kind: kind, started_at: started_at, type: type, location: location}}
    end
  end

  defp decode_action(_map), do: :error

  defp decode_replace(%{"from_epoch" => epoch} = map) when is_integer(epoch) and epoch > 0 do
    with {:ok, %DateTime{} = started_at} <- optional_time(map["started_at"]),
         {:ok, old} <- optional(map["old"], &decode_set/1),
         {:ok, move_started_at} <- optional_time(map["move_started_at"]),
         {:ok, candidate_id} <- optional_text(map["candidate_id"]),
         {:ok, moved_at} <- optional_time(map["moved_at"]),
         {:ok, deleted_at} <- optional_time(map["deleted_at"]),
         {:ok, failure} <- optional(map["failure"], &decode_failure/1) do
      {:ok,
       %{
         from_epoch: epoch,
         started_at: started_at,
         old: old,
         move_started_at: move_started_at,
         candidate_id: candidate_id,
         moved_at: moved_at,
         deleted_at: deleted_at,
         failure: failure
       }}
    end
  end

  defp decode_replace(_map), do: :error

  defp decode_set(%{} = map) do
    with {:ok, ref} <- optional_text(map["ref"]),
         {:ok, server} <- optional(map["server"], &decode_server/1),
         {:ok, firewall} <- optional(map["firewall"], &decode_firewall/1),
         {:ok, ips} <- decode_ips(map["primary_ips"]) do
      {:ok, %{ref: ref, server: server, firewall: firewall, primary_ips: ips}}
    end
  end

  defp decode_set(_map), do: :error

  defp decode_server(%{"name" => name, "status" => status} = map) when is_binary(name) do
    with {:ok, status} <- status(status),
         {:ok, id} <- optional_id(map["id"]),
         {:ok, type} <- text(map["type"]),
         {:ok, location} <- text(map["location"]),
         {:ok, ipv4} <- optional_text(map["ipv4"]),
         {:ok, power} <- optional_text(map["power"]),
         {:ok, created_at} <- optional_time(map["created_at"]),
         {:ok, seen_at} <- optional_time(map["seen_at"]),
         {:ok, total_monthly} <- optional_text(map["total_monthly"]),
         {:ok, currency} <- optional_text(map["currency"]) do
      {:ok,
       %{
         name: name,
         id: id,
         status: status,
         type: type,
         location: location,
         ipv4: ipv4,
         power: power,
         created_at: created_at,
         seen_at: seen_at,
         total_monthly: total_monthly,
         currency: currency
       }}
    end
  end

  defp decode_server(_map), do: :error

  defp decode_firewall(%{"name" => name, "status" => status} = map) when is_binary(name) do
    with {:ok, status} <- status(status),
         {:ok, id} <- optional_id(map["id"]) do
      {:ok, %{name: name, id: id, status: status}}
    end
  end

  defp decode_firewall(_map), do: :error

  defp decode_ips(ips) when is_list(ips) do
    decoded = Enum.map(ips, &decode_ip/1)

    if Enum.all?(decoded, &match?({:ok, _ip}, &1)),
      do: {:ok, Enum.map(decoded, fn {:ok, ip} -> ip end)},
      else: :error
  end

  defp decode_ips(_ips), do: :error

  defp decode_ip(%{"id" => id, "type" => type} = map) when type in ["ipv4", "ipv6"] do
    with {:ok, id} <- id(id),
         {:ok, ip} <- optional_text(map["ip"]),
         do: {:ok, %{id: id, type: type, ip: ip}}
  end

  defp decode_ip(_map), do: :error

  defp decode_failure(%{"reason" => reason, "sentence" => sentence} = map)
       when is_binary(reason) and is_binary(sentence) do
    with {:ok, next} <- optional_text(map["next_location"]),
         {:ok, %DateTime{} = at} <- optional_time(map["at"]),
         {:ok, action} <- optional_kind(map["action"]),
         {:ok, type} <- optional_text(map["type"]),
         {:ok, location} <- optional_text(map["location"]) do
      {:ok,
       %{
         reason: reason,
         sentence: sentence,
         next_location: next,
         at: at,
         action: action,
         type: type,
         location: location
       }}
    end
  end

  defp decode_failure(_map), do: :error

  defp optional(nil, _decode), do: {:ok, nil}
  defp optional(value, decode), do: decode.(value)

  defp status(word) do
    case Map.fetch(@status_words, word) do
      {:ok, status} -> {:ok, status}
      :error -> :error
    end
  end

  defp text(value) when is_binary(value) and value != "", do: {:ok, value}
  defp text(_value), do: :error

  defp optional_text(nil), do: {:ok, nil}
  defp optional_text(value), do: text(value)

  defp optional_kind(nil), do: {:ok, nil}
  defp optional_kind(kind) when kind in @action_kinds, do: {:ok, kind}
  defp optional_kind(_kind), do: :error

  defp optional_word(nil, _words), do: {:ok, nil}

  defp optional_word(word, words) when is_binary(word),
    do: if(word in words, do: {:ok, String.to_existing_atom(word)}, else: :error)

  defp optional_word(_word, _words), do: :error

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(id), do: id(id)

  # The provider's own id, opaque: a string, and nothing else.
  defp id(id) when is_binary(id) and byte_size(id) in 1..128, do: {:ok, id}
  defp id(_id), do: :error

  defp optional_time(nil), do: {:ok, nil}

  defp optional_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, 0} -> {:ok, at}
      _invalid -> :error
    end
  end

  defp optional_time(_text), do: :error
end
