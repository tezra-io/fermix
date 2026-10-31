defmodule FermixCore.Management.HomeSummary do
  @moduledoc """
  `home.status.summary` (M75 lean v1 §7): where Always On stands, in one
  sentence with at most one action, worked out once here so the Mac app, the
  Linux app, the setup page and `fermix home status` all say the same thing.

      summary: {state, sentence, action: {id, label} | null, detail}

  `summary/1` is pure: it reads the facts `gather/5` collects (the role, the
  move's phase, the candidates held, the provisioner's ledger
  (`Provision.Ledger.state/2`), the enrollment window and the link as the rail
  says them (`Home.Link.status/0`), the last readiness review, the snapshots,
  the disk, and on a linked desktop the server's own `home.status`). Its words
  are `Management.Copy`'s (`summary_sentence/2`, `summary_label/2`).

  `state` is one of `states/0`:

    * the computer that sets Always On up, before the move: `off`, `connect`
      (a code for a server of the owner's own is open, or Hetzner refused the
      token before anything was created), `choose` (the token works),
      `creating` (starting, installing, connecting, or deleting), `ready`,
      `undone` (a move was undone and its server is still held);
    * the computer the move left: `moving` (its last word, once it waits on
      the server's confirmation, is that Fermix keeps trying), `undone` while
      it restarts as it was, `on`, `retired` (no link, or the server forgot
      this computer);
    * the server: `candidate` while it waits for its move, `primary` after;
    * `problem`, with its `kind` (`problems/0`) in `detail` and the one action
      that fixes it, or Learn more where none does.

  Times count the way the design asks: a server that never checked in is a
  problem after 30 minutes of its code being open while this computer is
  awake (the window's `awake_ms`, a monotonic count), and one that stopped
  answering after 10 minutes of no session, counted the same way (the link's
  `down_ms`). The last backup is old past 3 days.

  On the computer the home left, a replace of the server Fermix created on
  Hetzner (`Ledger.state/1`'s `replace`) leads while it runs: creating the
  new server (`creating`, with Cancel), its code and its enrollment as the
  old server's own `home.status` draws them (`primary_home`'s `enrollment`
  and `candidates`: starting, installing, connecting, then `ready` with Move
  now), the move to it (`moving`, before any silence of the old server, which
  serves nothing while it runs), removing the old server, or deleting the new
  one; a failure is a `problem` with its one action (`delete_failed` and
  Delete when the old server could not be deleted). Until the move is done
  the old server is the one the home lives on, and Hetzner's power actions,
  which reach only the new one, are not offered for it. The new server's
  code lives on the old server, which never sleeps, so its 30 minutes count
  from its creation.

  `detail` holds what §7 lists and nothing else: on `off` the token step its
  Set up opens, on `connect` the "How to get one" steps, on `choose` how
  Hetzner bills, on `ready` the server's facts, the readiness warnings and
  blocks and until when it waits, on `on` the server, each backup, the space
  this computer's copies take, the disk, what lives on the server and the two
  actions Details offers (Back up now, Replace the server), and on `problem`
  its kind, what Fermix last saw and when, one note, and the other actions.
  """

  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Management.Copy

  require Logger

  @states ~w(off connect choose creating ready moving on undone retired candidate primary problem)
  @problems ~w(turned_off cannot_reach deleted not_set_up waited_too_long no_capacity
               account_limit read_only_token token_refused create_failed update disk_full
               backup_old not_ready unreadable delete_failed)
  @actions ~w(set_up create_server cancel move_now try_again learn_more turn_on restart_server
              start_again create_in open_hetzner paste_token update back_up_now replace_server
              check_again own_server delete_server)

  @unreachable_ms 10 * 60_000
  @setup_ms 30 * 60_000
  @backup_old_s 3 * 86_400
  @day_s 86_400
  @moving ~w(requested streaming committed)
  @undoing ~w(aborting undoing)
  @receiving ~w(receiving staged activating)

  @type facts :: %{
          role: :primary | :device | :candidate,
          host_os: :macos | :linux,
          now: DateTime.t(),
          linked: boolean(),
          moved: map() | nil,
          move: map() | nil,
          link: map(),
          candidates: [map()],
          provision: map(),
          review: map() | nil,
          snapshots: map(),
          disk: map() | nil,
          primary_home: map() | nil,
          primary_too_old: boolean(),
          copies_bytes: non_neg_integer() | nil,
          stays_here: [:imessage | :voice | :meetings]
        }
  @type summary :: %{String.t() => term()}

  @doc "Every state a summary takes, in the order the protocol lists them."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Every problem kind a `problem` names in `detail.kind`."
  @spec problems() :: [String.t()]
  def problems, do: @problems

  @doc "Every action id a summary offers, as its action or in `detail`."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "The summary for `facts` (`gather/5`'s)."
  @spec summary(facts()) :: summary()
  def summary(%{role: :candidate} = facts), do: candidate(facts)
  def summary(%{role: :device} = facts), do: device(facts)
  def summary(%{role: :primary, link: %{desktops: [_ | _]}} = facts), do: server(facts)
  def summary(%{role: :primary} = facts), do: setup(facts)

  @doc """
  The facts of `home`'s summary: `status` is the `home.status` record's own
  facts (`Management.Home.status/1` has gathered them, with
  `primary_too_old`), `link` the rail's status, and `opts` the seams `:now`
  and `:host_os`, and `:unreadable_files` (`Home.UnreadableFiles`, or nil
  for a verb with no engine tree). Reads the ledger, the last readiness
  review, on the primary what its settings turn on that stops after a move,
  and, on a desktop, the size of its stored copies.
  """
  @spec gather(Path.t(), map(), map(), map(), keyword()) :: facts()
  def gather(home, %{role: role} = record, link, status, opts)
      when is_binary(home) and is_map(link) and is_map(status) and is_list(opts) do
    host_os = Keyword.get_lazy(opts, :host_os, &host_os/0)
    reads = Keyword.take(opts, [:unreadable_files])

    %{
      role: role,
      host_os: host_os,
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      linked: DesktopLink.linked?(record, home),
      moved: status.moved,
      move: status.move,
      link: link,
      candidates: status.candidates,
      provision: Ledger.state(home, "hetzner", reads),
      review: review(home, role),
      snapshots: status.snapshots,
      disk: status.disk,
      primary_home: status.primary_home,
      primary_too_old: Map.get(status, :primary_too_old, false),
      copies_bytes: copies_bytes(home, role),
      stays_here: stays_here(home, role, host_os, reads)
    }
  end

  # -- the computer that sets Always On up ---------------------------------------

  defp setup(facts) do
    checks = [&undone/1, &ledger_problem/1, &provisioned/1, &own_server/1, &chosen/1]
    Enum.find_value(checks, & &1.(facts)) || off(facts)
  end

  defp undone(%{move: %{"phase" => phase}} = facts) when phase in ["aborted", "undoing"] do
    if target(facts), do: view("undone", sentence(:undone, facts), action(:try_again), %{})
  end

  defp undone(_facts), do: nil

  # What the ledger itself says is wrong, before anything about a server.
  defp ledger_problem(%{provision: %{state: :unreadable, sentence: sentence}}),
    do: problem("unreadable", sentence, :learn_more, %{})

  defp ledger_problem(%{provision: %{token: :refused, server: server}} = facts) do
    if standing?(server),
      do: problem("token_refused", sentence(:token_refused, facts), :paste_token, %{}),
      else: connect(facts)
  end

  defp ledger_problem(%{provision: %{state: :failed, failure: failure}} = facts),
    do: failure_problem(failure, facts)

  defp ledger_problem(_facts), do: nil

  defp failure_problem(%{reason: "unavailable", next_location: next} = failure, facts)
       when is_binary(next) do
    problem("no_capacity", failure.sentence, action(:create_in, %{location: next}), %{
      "next_location" => next,
      "seen_at" => iso(failure.at)
    })
    |> before_move(facts)
  end

  defp failure_problem(%{reason: reason} = failure, facts) do
    {kind, act, alternatives} =
      case reason do
        "unavailable" -> {"no_capacity", :learn_more, []}
        "account_limit" -> {"account_limit", :open_hetzner, [:own_server]}
        "read_only_token" -> {"read_only_token", :paste_token, []}
        "gone" -> {"deleted", :start_again, []}
        _other -> {"create_failed", :start_again, []}
      end

    problem(kind, failure.sentence, act, %{
      "seen_at" => iso(failure.at),
      "alternatives" => Enum.map(alternatives, &action/1)
    })
    |> before_move(facts)
  end

  defp provisioned(%{provision: %{state: :deleting}}),
    do: view("creating", Copy.summary_sentence(:deleting, %{}), nil, %{})

  defp provisioned(%{provision: %{state: :creating}}), do: creating(:starting)

  defp provisioned(%{provision: %{state: :gone, server: server}} = facts),
    do: deleted(server, :start_again) |> before_move(facts)

  defp provisioned(%{provision: %{state: :created, server: server}} = facts),
    do: created(server, facts)

  defp provisioned(_facts), do: nil

  defp created(%{power: "off"} = server, facts),
    do: turned_off(server) |> before_move(facts)

  defp created(server, facts), do: waiting_server(window(facts), server, facts)

  # The created server, by where its own 24-hour code stands (L15).
  defp waiting_server(%{kind: :provisioned, state: :open} = window, server, facts) do
    cond do
      Map.get(window, :awake_ms, 0) >= @setup_ms -> not_set_up(server, facts)
      server.power == "running" -> creating(:installing)
      true -> creating(:starting)
    end
  end

  defp waiting_server(%{kind: :provisioned, state: :used, candidate_id: nil}, _server, _facts),
    do: creating(:connecting)

  defp waiting_server(%{kind: :provisioned, state: :used, candidate_id: id}, server, facts) do
    case held(facts, id) do
      nil ->
        problem("waited_too_long", sentence(:waited_too_long, facts), :start_again, %{})
        |> before_move(facts)

      candidate ->
        ready(candidate, server, facts)
    end
  end

  defp waiting_server(_window, server, facts), do: not_set_up(server, facts)

  defp not_set_up(_server, facts) do
    problem("not_set_up", sentence(:not_set_up, facts), :start_again, %{
      "alternatives" => [action(:own_server), action(:open_hetzner)]
    })
    |> before_move(facts)
  end

  # A server of the owner's own (`home.enroll.open`), with no Hetzner server.
  defp own_server(facts) do
    case {target(facts), window(facts)} do
      {%{} = candidate, _window} ->
        ready(candidate, nil, facts)

      {nil, %{kind: :manual, state: :open}} ->
        connect(facts)

      {nil, %{kind: :manual, state: :used, candidate_id: nil}} ->
        view("creating", Copy.summary_sentence(:connecting, %{}), nil, %{})

      _nothing ->
        nil
    end
  end

  defp chosen(%{provision: %{state: :connected}} = facts) do
    view("choose", sentence(:choose, facts), action(:create_server), %{
      "billing" => sentence(:billing, facts)
    })
  end

  defp chosen(_facts), do: nil

  defp off(facts) do
    view("off", sentence(:off, facts, %{stays_here: facts.stays_here}), action(:set_up), %{
      "connect" => Map.put(connect_detail(), "sentence", sentence(:connect, facts))
    })
  end

  defp connect(facts), do: view("connect", sentence(:connect, facts), nil, connect_detail())

  defp connect_detail,
    do: %{"steps" => Copy.token_steps(), "alternatives" => [action(:own_server)]}

  defp creating(step),
    do: view("creating", Copy.summary_sentence(step, %{}), action(:cancel), %{})

  # The server is held and waits for Move now, unless the last review blocks.
  defp ready(candidate, server, facts) do
    items = review_items(facts.review, candidate["candidate_id"])

    case for(%{"status" => "block", "sentence" => block} <- items, do: block) do
      [block | _more] ->
        problem("not_ready", Copy.summary_sentence(:not_ready, %{block: block}), :check_again, %{
          "readiness" => items
        })

      [] ->
        view("ready", sentence(:ready, facts), action(:move_now), %{
          "server" => server_facts(candidate, server),
          "readiness" => items,
          "waits_until" => candidate["expires_at"]
        })
    end
  end

  # The warnings and blocks of the last review of this server; nothing when
  # all is well or none was made.
  defp review_items(%{candidate_id: id, items: items}, id),
    do: Enum.filter(items, &(&1["status"] in ["warn", "block"]))

  defp review_items(_review, _candidate_id), do: []

  defp server_facts(candidate, server) do
    %{
      "name" => (server && server.name) || candidate["name"],
      "type" => server && String.upcase(server.type),
      "location" => server && Copy.city(server.location),
      "ipv4" => server && server.ipv4,
      "system" => "#{candidate["os"]} #{candidate["arch"]}",
      "version" => candidate["version"]
    }
  end

  # A problem before the move, while a server Fermix created still stands:
  # Details says it costs money and offers to delete it (during a replace,
  # the new one).
  defp before_move(view, %{provision: %{server: server} = provision}) do
    if standing?(server) do
      detail = view["detail"]
      {note, delete} = server_costs(provision)

      %{
        view
        | "detail" => %{
            detail
            | "note" => detail["note"] || note,
              "alternatives" => detail["alternatives"] ++ [delete]
          }
      }
    else
      view
    end
  end

  defp server_costs(%{replace: %{}}),
    do: {Copy.summary_sentence(:new_server_costs, %{}), action(:delete_server, %{which: "new"})}

  defp server_costs(_provision),
    do: {Copy.summary_sentence(:server_costs, %{}), action(:delete_server)}

  # -- the computer the move left ------------------------------------------------

  defp device(%{move: %{"phase" => "committing"}} = facts),
    do: view("moving", sentence(:waiting, facts), nil, %{})

  defp device(%{move: %{"phase" => phase}} = facts) when phase in @moving,
    do: view("moving", sentence(:moving, facts), nil, %{})

  defp device(%{move: %{"phase" => phase}} = facts) when phase in @undoing,
    do: view("undone", sentence(:undone, facts), nil, %{})

  defp device(%{linked: false} = facts), do: retired(facts)
  defp device(%{link: %{primary: %{status: :revoked}}} = facts), do: retired(facts)
  defp device(facts), do: desktop(facts)

  defp retired(facts), do: view("retired", sentence(:retired, facts), action(:learn_more), %{})

  defp desktop(facts) do
    checks = [
      &replace_moving/1,
      &away/1,
      &too_old/1,
      &token_stopped/1,
      &server_disk/1,
      &replacing/1,
      &desktop_backup/1
    ]

    Enum.find_value(checks, & &1.(facts)) || on(facts)
  end

  # No session with the server: what Hetzner last said, else ten minutes of
  # silence while this computer is awake.
  defp away(%{link: %{primary: %{status: status} = link}, provision: provision})
       when status in [:unreachable, :stale] do
    {server, powered?} = home_server(provision)

    cond do
      match?(%{status: :gone}, server) -> deleted(server, :learn_more)
      match?(%{power: "off"}, server) -> turned_off(server, :turned_off, powered?)
      (Map.get(link, :down_ms) || 0) >= @unreachable_ms -> cannot_reach(server, powered?)
      true -> nil
    end
  end

  defp away(_facts), do: nil

  defp cannot_reach(%{status: :created} = server, powered?) do
    act = if powered?, do: :restart_server, else: :learn_more

    problem("cannot_reach", Copy.summary_sentence(:cannot_reach, %{}), act, %{
      "seen_at" => iso(server.seen_at)
    })
  end

  defp cannot_reach(_server, _powered?),
    do: problem("cannot_reach", Copy.summary_sentence(:cannot_reach, %{}), :learn_more, %{})

  # The server the home lives on, and whether Hetzner's power actions reach
  # it: during a replace the old one until the move is done, which they do
  # not (they act on the new server).
  defp home_server(%{replace: %{current: :old, old: old}}), do: {old, false}
  defp home_server(provision), do: {provision.server, true}

  defp too_old(%{primary_too_old: true} = facts),
    do: problem("update", sentence(:update, facts), :update, %{})

  defp too_old(_facts), do: nil

  defp token_stopped(%{provision: %{token: :refused} = provision} = facts) do
    {server, _powered?} = home_server(provision)

    if standing?(server) or standing?(provision.server),
      do: problem("token_refused", sentence(:token_refused, facts), :paste_token, %{})
  end

  defp token_stopped(_facts), do: nil

  defp server_disk(%{primary_home: %{"disk" => disk}}), do: disk_problem(disk, :disk_full)
  defp server_disk(_facts), do: nil

  defp desktop_backup(%{primary_home: %{"snapshots" => snapshots}} = facts) do
    case newest_backup(snapshots) do
      nil -> no_backup(facts)
      at -> old_backup(at, :backup_old, facts)
    end
  end

  defp desktop_backup(_facts), do: nil

  # No backup has finished since the move: counted from the move itself.
  defp no_backup(%{moved: %{moved_at: %DateTime{} = moved_at}} = facts) do
    age = DateTime.diff(facts.now, moved_at, :second)

    if age > @backup_old_s,
      do:
        problem(
          "backup_old",
          sentence(:backup_none, facts, %{days: div(age, @day_s)}),
          :back_up_now,
          %{}
        )
  end

  defp no_backup(_facts), do: nil

  defp on(facts) do
    view("on", on_sentence(facts), nil, %{
      "server" => on_server(facts),
      "backups" => backups(get_in(facts, [:primary_home, "snapshots"])),
      "copies_bytes" => facts.copies_bytes,
      "disk_used" => get_in(facts, [:primary_home, "disk", "used"]),
      "data" => sentence(:data, facts, %{provider: provider(facts)}),
      "actions" => [action(:back_up_now), action(:replace_server)]
    })
  end

  defp on_sentence(%{primary_home: %{"snapshots" => snapshots}} = facts) do
    case newest_backup(snapshots) do
      nil -> sentence(:on_no_backup, facts)
      at -> sentence(:on_backup, facts, %{age: DateTime.diff(facts.now, at, :second)})
    end
  end

  defp on_sentence(facts), do: sentence(:on, facts)

  defp on_server(%{provision: %{server: server}} = facts) do
    %{
      "name" => (server && server.name) || link_name(facts),
      "location" => server && Copy.city(server.location),
      "version" => get_in(facts, [:primary_home, "version"])
    }
  end

  defp link_name(%{link: %{primary: %{name: name}}}), do: name
  defp link_name(%{moved: %{to: to}}), do: to
  defp link_name(_facts), do: nil

  defp provider(%{provision: %{server: %{}}}), do: "Hetzner"
  defp provider(_facts), do: "whoever hosts it"

  # -- a replace of the server, on the computer the home left -------------------

  # The old server serves nothing while the move runs, so its silence then is
  # the move, not a problem.
  defp replace_moving(%{provision: %{replace: %{state: :moving}}} = facts),
    do: view("moving", sentence(:replace_moving, facts), nil, %{})

  defp replace_moving(_facts), do: nil

  defp replacing(%{provision: %{replace: %{state: state} = replace}} = facts),
    do: replace_step(state, replace, facts)

  defp replacing(_facts), do: nil

  defp replace_step(:creating, _replace, facts), do: new_server_step(:replace_creating, facts)
  defp replace_step(:waiting, _replace, facts), do: new_server(facts.provision.server, facts)

  defp replace_step(:deleting, _replace, facts),
    do: view("creating", sentence(:replace_deleting, facts), nil, %{})

  defp replace_step(:cancelling, _replace, facts),
    do: view("creating", sentence(:replace_cancelling, facts), nil, %{})

  defp replace_step(:failed, %{current: :new, failure: failure}, _facts),
    do: delete_failed(failure)

  defp replace_step(:failed, %{failure: failure}, facts), do: failure_problem(failure, facts)
  defp replace_step(state, _replace, _facts) when state in [:moving, :done], do: nil

  # The new server, by where the old server's 24-hour code for it stands.
  defp new_server(%{power: "off"} = server, facts),
    do: server |> turned_off(:replace_turned_off, true) |> before_move(facts)

  defp new_server(server, facts), do: new_server_window(new_window(facts), server, facts)

  defp new_server_window(%{"state" => "open"}, server, facts) do
    if older_than?(server.created_at, @setup_ms, facts),
      do: new_server_problem("not_set_up", :replace_not_set_up, facts),
      else: new_server_step(power_step(server), facts)
  end

  defp new_server_window(%{"state" => "used", "candidate_id" => nil}, _server, facts),
    do: new_server_step(:replace_connecting, facts)

  defp new_server_window(%{"state" => "used", "candidate_id" => id}, server, facts) do
    case held_by_server(facts, id) do
      nil ->
        new_server_problem("waited_too_long", :replace_waited_too_long, facts)

      candidate ->
        view("ready", sentence(:replace_ready, facts), action(:move_now), %{
          "server" => server_facts(candidate, server),
          "readiness" => [],
          "waits_until" => candidate["expires_at"]
        })
    end
  end

  defp new_server_window(%{"state" => "expired"}, _server, facts),
    do: new_server_problem("not_set_up", :replace_not_set_up, facts)

  # The old server's part is missing, or holds no such code: what Hetzner says.
  defp new_server_window(nil, server, facts), do: new_server_step(power_step(server), facts)

  defp power_step(%{power: "running"}), do: :replace_installing
  defp power_step(_server), do: :replace_starting

  defp new_server_step(key, facts),
    do: view("creating", sentence(key, facts), action(:cancel), %{})

  defp new_server_problem(kind, key, facts),
    do: problem(kind, sentence(key, facts), :start_again, %{}) |> before_move(facts)

  # Deleting the old server after the move stopped: it stays, and costs.
  defp delete_failed(failure) do
    problem("delete_failed", failure.sentence, action(:delete_server, %{which: "old"}), %{
      "note" => Copy.summary_sentence(:old_server_costs, %{}),
      "seen_at" => iso(failure.at)
    })
  end

  # The old server's window for the new one, as its own `home.status` says.
  defp new_window(facts) do
    case get_in(facts, [:primary_home, "enrollment"]) do
      %{"kind" => "provisioned"} = window -> window
      _none -> nil
    end
  end

  defp held_by_server(facts, id) do
    candidates = get_in(facts, [:primary_home, "candidates"]) || []
    Enum.find(candidates, &(&1["candidate_id"] == id))
  end

  defp older_than?(%DateTime{} = at, ms, facts),
    do: DateTime.diff(facts.now, at, :millisecond) >= ms

  defp older_than?(nil, _ms, _facts), do: false

  # -- the server ----------------------------------------------------------------

  defp server(facts) do
    disk = disk_problem(facts.disk, :server_disk_full)
    disk || server_backup(facts) || view("primary", sentence(:primary, facts), nil, %{})
  end

  defp server_backup(facts) do
    case newest_backup(facts.snapshots) do
      nil -> nil
      at -> old_backup(at, :server_backup_old, facts)
    end
  end

  # -- the server before its move ------------------------------------------------

  defp candidate(%{move: %{"phase" => "expired"}} = facts),
    do: problem("waited_too_long", sentence(:server_waited_too_long, facts), :learn_more, %{})

  defp candidate(%{move: %{"phase" => "failed"}} = facts),
    do: problem("not_set_up", sentence(:server_not_set_up, facts), :learn_more, %{})

  defp candidate(%{move: %{"phase" => phase}} = facts) when phase in @receiving,
    do: view("candidate", sentence(:candidate_receiving, facts), nil, %{})

  defp candidate(facts), do: view("candidate", sentence(:candidate_waiting, facts), nil, %{})

  # -- problems shared by more than one place ------------------------------------

  # `powered?`: whether Turn it on reaches this server.
  defp turned_off(server, key \\ :turned_off, powered? \\ true) do
    act = if powered?, do: :turn_on, else: :learn_more

    problem("turned_off", Copy.summary_sentence(key, %{}), act, %{
      "note" => Copy.summary_sentence(:turned_off_cost, %{}),
      "seen_at" => iso(server.seen_at)
    })
  end

  defp deleted(server, act) do
    problem("deleted", Copy.summary_sentence(:deleted, %{}), act, %{
      "seen_at" => iso(server && server.seen_at)
    })
  end

  defp disk_problem(%{"used" => used, "nearly_full" => true}, key),
    do:
      problem(
        "disk_full",
        Copy.summary_sentence(key, %{percent: round(used * 100)}),
        :learn_more,
        %{}
      )

  defp disk_problem(_disk, _key), do: nil

  defp old_backup(at, key, facts) do
    age = DateTime.diff(facts.now, at, :second)

    if age > @backup_old_s,
      do:
        problem("backup_old", sentence(key, facts, %{days: div(age, @day_s)}), :back_up_now, %{
          "seen_at" => iso(at)
        })
  end

  # -- facts, read ---------------------------------------------------------------

  defp window(%{link: link}), do: Map.get(link, :enrollment)

  # The server the move goes to: the one the created server's code enrolled,
  # else the newest held.
  defp target(%{candidates: []}), do: nil

  defp target(facts) do
    case window(facts) do
      %{candidate_id: id} when is_binary(id) -> held(facts, id) || newest(facts.candidates)
      _window -> newest(facts.candidates)
    end
  end

  defp held(facts, id), do: Enum.find(facts.candidates, &(&1["candidate_id"] == id))
  defp newest(candidates), do: Enum.max_by(candidates, & &1["enrolled_at"])

  defp standing?(%{status: status}), do: status != :gone
  defp standing?(nil), do: false

  defp newest_backup(%{"targets" => targets}) do
    targets
    |> Enum.flat_map(&List.wrap(get_in(&1, ["last_verified", "at"])))
    |> Enum.map(&time/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp newest_backup(_snapshots), do: nil

  defp backups(%{"targets" => targets}) do
    for %{"label" => label, "last_verified" => %{"at" => at}} <- targets,
        do: %{"place" => label, "at" => at}
  end

  defp backups(_snapshots), do: []

  defp time(text) do
    {:ok, at, 0} = DateTime.from_iso8601(text)
    at
  end

  # -- the summary's shape -------------------------------------------------------

  defp view(state, sentence, action, detail) when state in @states,
    do: %{"state" => state, "sentence" => sentence, "action" => action, "detail" => detail}

  defp problem(kind, sentence, %{"id" => _id} = act, extra) when kind in @problems do
    detail =
      Map.merge(%{"kind" => kind, "note" => nil, "seen_at" => nil, "alternatives" => []}, extra)

    view("problem", sentence, act, detail)
  end

  defp problem(kind, sentence, act, extra) when is_atom(act),
    do: problem(kind, sentence, action(act), extra)

  defp action(id, values \\ %{}) when is_atom(id) do
    true = Atom.to_string(id) in @actions
    %{"id" => Atom.to_string(id), "label" => Copy.summary_label(id, values)}
  end

  defp sentence(key, facts, values \\ %{}),
    do: Copy.summary_sentence(key, Map.put(values, :machine, machine(facts.host_os)))

  defp machine(:macos), do: "Mac"
  defp machine(:linux), do: "computer"

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # -- gathering -----------------------------------------------------------------

  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      _other -> :linux
    end
  end

  # The last review of the move, whatever its age: on the computer that moves.
  defp review(home, :primary) do
    case Move.last_review(home) do
      {:ok, review} ->
        review

      :none ->
        nil

      {:error, reason} ->
        Logger.error("home status: the move's review could not be read: #{inspect(reason)}")
        nil
    end
  end

  defp review(_home, _role), do: nil

  # What stops after a move, which only the computer that sets it up says.
  defp stays_here(home, :primary, host_os, reads) do
    case MoveReadiness.stays_here(home, host_os == :macos, reads) do
      {:ok, features} -> features
      {:error, _sentence} -> []
    end
  end

  defp stays_here(_home, _role, _host_os, _reads), do: []

  # The space the server's backups take on this desktop (`Desktop.SnapshotStore`).
  defp copies_bytes(home, :device) do
    home
    |> Capture.dir()
    |> Path.join("*.fxsnap")
    |> Path.wildcard()
    |> Enum.reduce(0, &(&2 + copy_bytes(&1)))
  end

  defp copies_bytes(_home, _role), do: nil

  # A copy the store rotated out between the listing and the read takes no
  # space; any other failure is logged and counted as none.
  defp copy_bytes(file) do
    case File.stat(file) do
      {:ok, %File.Stat{size: size}} ->
        size

      {:error, :enoent} ->
        0

      {:error, reason} ->
        Logger.warning("home status: #{file} could not be read: #{inspect(reason)}")
        0
    end
  end
end
