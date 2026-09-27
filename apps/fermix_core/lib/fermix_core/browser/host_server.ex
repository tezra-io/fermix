defmodule FermixCore.Browser.HostServer do
  @moduledoc """
  The browser surface over the Fermix app's own browser pane (`:fermix_app`).

  The macOS app hosts a WebKit pane and connects to `browser_host.sock`; this
  backend drives it as `CDP.Backend` drives Chrome. Each operation is one
  request on the app's connection (`FermixCore.BrowserHost.Link`), answered by
  the app and bounded by the browser's own action and navigation timeouts. The
  app reads the page and acts on it; the engine keeps what is the engine's:
  the navigation and read policy (`Policy`), the rendering of the page the app
  hands back (`Snapshot.render/2`, the renderer Chrome's pages use), the refs
  a snapshot leaves behind, and whether an action changed the page.

  ## The task

  A pane task is this backend's runtime. It starts with the profile's first
  operation, when the host's last report says the pane is available, and it is
  bound there to two processes:
  - the connection the host was on, and to no other: requests are never sent
    on a later connection, and the tabs are named by the connection they
    belong to (`h<connection>:<tab>`), so a tab id can never reach another
    connection's tab;
  - the caller, the process that made the first call: a conversation's turn,
    a scheduled run, a subagent. When it ends, however it ends, a cancel
    included, the task ends and the profile stops, so the next browser use is
    decided afresh.

  A task ends by telling the connection so (`Link.release/2`), which writes the
  task's `task.release` behind every request the task sent: both leave this
  one process in order, so a release can never overtake a queued `tab.open`,
  and a request already sent when the task ends still runs before it. The
  connection writes it at most once.

  ## A pane that goes away

  Before every operation the host's last report is read (`HostAvailability`).
  A pane that is no longer available, a connection that is gone or replaced,
  an app that is quitting, or an answer of `host_unavailable` fails the task
  where it stands: the operation answers `host_lost` with the app's reason,
  the profile is reaped, and the turn is marked (`TurnMarker`) so that its
  later browser calls answer the same sentence instead of running in Chrome.
  """

  @behaviour FermixCore.Browser.Backend

  alias FermixCore.Browser.Capabilities
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.Policy
  alias FermixCore.Browser.Snapshot
  alias FermixCore.Browser.TurnMarker
  alias FermixCore.Browser.Upload
  alias FermixCore.BrowserHost.Link
  alias FermixCore.Net.Guard
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Trace

  require Logger

  # The `act` kinds that can restructure a page enough to be worth a look
  # afterwards, as in Chrome; `press` is decided by its key.
  @observing_kinds ~w(click submit click_coords)
  @download_buffer 10
  @reason_chars 200

  @stale_ref "Element ref is stale or unknown. Refs belong to the snapshot they came from, and " <>
               "the page has changed since. Take a fresh `snapshot` and use a ref from it."
  @dialog_blocked "A JavaScript dialog is blocking browser actions. Clear it first with the " <>
                    "`dialog` action (`decision`: \"accept\" or \"dismiss\"), then retry this action."

  @impl true
  def init(opts) when is_list(opts) do
    %{
      owner_key: Keyword.fetch!(opts, :owner_key),
      profile_name: Keyword.fetch!(opts, :profile_name),
      config: Keyword.fetch!(opts, :config),
      host_availability: Keyword.get(opts, :host_availability, HostAvailability),
      turn_marker: Keyword.get(opts, :turn_marker, TurnMarker),
      resolver: Keyword.get_lazy(opts, :resolver, &default_resolver/0),
      task: nil,
      lost: nil,
      tabs: %{},
      active: nil,
      ref_maps: %{},
      observations: %{},
      dialogs: [],
      downloads: [],
      resolved: %{}
    }
  end

  # `Net.Guard`'s resolver, bounded by the browser's own lookup budget, as the
  # CDP backend uses it; config/test.exs pins `:browser_resolver`.
  defp default_resolver do
    timeout = Config.address_limits().lookup_timeout_ms
    Application.get_env(:fermix_core, :browser_resolver, &Guard.resolve(&1, timeout))
  end

  @impl true
  def status(state), do: %{"running" => not is_nil(state.task), "tabs" => map_size(state.tabs)}

  @impl true
  def start(context, state), do: ensure_task(context, state)

  @impl true
  def stop(%{task: nil} = state), do: state

  def stop(%{task: task} = state) do
    :ok = Link.release(task.connection, task.id)
    Process.demonitor(task.connection_ref, [:flush])
    Process.demonitor(task.caller_ref, [:flush])

    trace(task.agent, "browser_host_task_end", state, %{
      "task_id" => task.id,
      "lost" => lost?(state)
    })

    %{
      state
      | task: nil,
        tabs: %{},
        active: nil,
        ref_maps: %{},
        observations: %{},
        dialogs: [],
        downloads: []
    }
  end

  defp lost?(%{lost: nil}), do: false
  defp lost?(_state), do: true

  # The caller ended (its turn finished or was cancelled): the task ends with
  # it, and so does the profile.
  @impl true
  def handle_message({:DOWN, ref, :process, _pid, _reason}, %{task: %{caller_ref: ref}} = state),
    do: {:stop, stop(state)}

  def handle_message(
        {:DOWN, ref, :process, _pid, _reason},
        %{task: %{connection_ref: ref}} = state
      ),
      do: lost_between_requests(state, "the app disconnected")

  def handle_message(
        {:browser_host_stopping, connection},
        %{task: %{connection: connection}} = state
      ),
      do: lost_between_requests(state, "the app is quitting")

  def handle_message(
        {:browser_host_event, connection, type, payload},
        %{task: %{connection: connection}} = state
      ),
      do: record_event(type, payload, state)

  # A server traps exits, and a late answer to a request that timed out lands
  # here: both are dropped.
  def handle_message(_message, state), do: state

  defp lost_between_requests(state, reason) do
    {:reap, _error, state} = lose(state, reason)
    {:stop, stop(state)}
  end

  @impl true
  def console_buffer(_state), do: []

  # ── operations ─────────────────────────────────────────────────────────────

  @impl true
  def open(args, context, state) do
    operate(context, state, fn state ->
      with {:ok, state} <- navigation_verdict(args["url"], state),
           {:ok, dir} <- ensure_dir(download_dir(state), state) do
        observe? = Map.get(args, "observe", true)

        payload =
          %{
            "task_id" => state.task.id,
            "url" => args["url"],
            "download_dir" => dir,
            "task_tab_cap" => state.config.max_tabs,
            "tab_cap" => state.config.max_tabs * state.config.max_live_profiles
          }
          |> observe_fields(observe?, fresh_options(state))

        state
        |> request("tab.open", payload, navigation_timeout(state.config))
        |> navigated(observe?)
      end
    end)
  end

  @impl true
  def navigate(args, context, state) do
    operate(context, state, fn state ->
      with {:ok, tab} <- resolve_tab(args["target"], state),
           {:ok, state} <- navigation_verdict(args["url"], state) do
        observe? = Map.get(args, "observe", true)

        payload =
          %{"tab_id" => tab.wire, "url" => args["url"]}
          |> observe_fields(observe?, fresh_options(state))

        state
        |> request("tab.navigate", payload, navigation_timeout(state.config))
        |> navigated(observe?)
      end
    end)
  end

  @impl true
  def snapshot(args, context, state) do
    operate(context, state, fn state ->
      with {:ok, opts} <- snapshot_options(args, state),
           {:ok, tab} <- resolve_tab(args["target"], state),
           payload = Map.put(wire_options(opts), "tab_id", tab.wire),
           {:ok, page, state} <- request(state, "page.snapshot", payload, action_timeout(state)),
           {:ok, state} <- read_gate(page["url"], state) do
        {:ok, rendered} = Snapshot.render(page["nodes"], opts)
        state = state |> put_page(tab.id, page) |> remember(tab.id, opts, rendered)
        {:ok, snapshot_result(tab.id, page, rendered), state}
      end
    end)
  end

  @impl true
  def tabs(_args, context, state) do
    operate(context, state, fn state ->
      with {:ok, result, state} <-
             request(state, "tab.list", %{"task_id" => state.task.id}, action_timeout(state)) do
        state = list_tabs(result["tabs"], state)
        {rows, state} = Enum.map_reduce(sorted_tabs(state), state, &tab_row/2)
        {:ok, %{"ok" => true, "tabs" => rows}, state}
      end
    end)
  end

  @impl true
  def focus(args, context, state) do
    operate(context, state, fn state ->
      with {:ok, tab} <- resolve_tab(args["target"], state),
           {:ok, result, state} <-
             request(state, "tab.focus", %{"tab_id" => tab.wire}, action_timeout(state)) do
        state = %{put_page(state, tab.id, result) | active: tab.id}
        {row, state} = tab_row(state.tabs[tab.id], state)
        {:ok, row, state}
      end
    end)
  end

  @impl true
  def close(args, context, state) do
    operate(context, state, fn state ->
      with {:ok, tab} <- resolve_tab(args["target"], state),
           {:ok, _result, state} <-
             request(state, "tab.close", %{"tab_id" => tab.wire}, action_timeout(state)) do
        {:ok, %{"ok" => true, "closed" => tab.id}, forget_tab(state, tab.id)}
      end
    end)
  end

  @impl true
  def screenshot(args, context, state) do
    capture(args, context, state, "page.screenshot", {"screenshots", "png"})
  end

  @impl true
  def pdf(args, context, state), do: capture(args, context, state, "page.pdf", {"pdf", "pdf"})

  # The app's wire carries neither: a page's console and its storage stay in
  # the app. Refused here, before anything is asked of the app.
  @impl true
  def console(_args, _context, state), do: refuse(:console, state)

  @impl true
  def storage(_args, _context, state), do: refuse(:storage, state)

  @impl true
  def webmcp(_args, _context, state), do: refuse(:webmcp, state)

  @impl true
  def dialog(%{"decision" => decision} = args, context, state)
      when decision in ["accept", "dismiss"] do
    operate(context, state, fn state ->
      with {:ok, tab} <- dialog_tab(args["target"], state),
           payload = dialog_payload(tab, decision, args["text"]),
           {:ok, _result, state} <-
             request(state, "dialog.resolve", payload, action_timeout(state)) do
        dialogs = Enum.reject(state.dialogs, &(&1["target"] == tab.id))
        {:ok, %{"ok" => true, "dialog" => decision}, %{state | dialogs: dialogs}}
      end
    end)
  end

  def dialog(_args, context, state) do
    operate(context, state, fn state ->
      {:ok, %{"ok" => true, "dialogs" => Enum.reverse(state.dialogs)}, state}
    end)
  end

  @impl true
  def cookies(%{"kind" => "clear"} = args, context, state) do
    operate(context, state, fn state ->
      with {:ok, tab} <- resolve_tab(args["target"], state),
           {:ok, result, state} <-
             request(state, "cookies.clear", %{"tab_id" => tab.wire}, action_timeout(state)) do
        {:ok, %{"ok" => true, "cleared" => result["cleared"]}, state}
      end
    end)
  end

  def cookies(args, context, state) do
    operate(context, state, fn state ->
      with {:ok, tab} <- resolve_tab(args["target"], state),
           {:ok, result, state} <-
             request(state, "cookies.get", %{"tab_id" => tab.wire}, action_timeout(state)),
           {:ok, state} <- read_gate(result["url"], state) do
        {:ok, %{"ok" => true, "cookies" => result["cookies"]}, state}
      end
    end)
  end

  @impl true
  def upload(args, context, state) do
    operate(context, state, fn state ->
      with {:ok, path} <- upload_path(args["path"], state),
           {:ok, tab} <- resolve_tab(args["target"], state),
           {:ok, ref} <- element_ref(tab, args["ref"], state),
           payload = %{"tab_id" => tab.wire, "ref" => ref, "path" => path},
           {:ok, _result, state} <- request(state, "page.upload", payload, action_timeout(state)) do
        {:ok, %{"ok" => true, "target" => tab.id, "uploaded" => Path.basename(path)}, state}
      end
    end)
  end

  @impl true
  def download(args, context, state) do
    operate(context, state, fn state ->
      config = state.config
      timeout = bounded(args["timeout_ms"], config.download_default_ms, config.download_max_ms)
      deadline = System.monotonic_time(:millisecond) + timeout
      await_download(state, deadline)
    end)
  end

  @impl true
  def act(%{"kind" => kind} = args, context, state) when is_binary(kind) do
    operate(context, state, fn state ->
      with {:ok, tab} <- resolve_tab(args["target"], state),
           :ok <- undialogged(tab, state),
           {:ok, fields} <- act_fields(args, tab, state) do
        mark = observation(kind, args, tab, state)

        payload =
          %{"tab_id" => tab.wire, "kind" => kind}
          |> Map.merge(fields)
          |> observe_fields(not is_nil(mark), mark && mark.opts)

        state
        |> request("page.act", payload, act_timeout(fields, mark, state.config))
        |> acted(kind, tab, mark)
      end
    end)
  end

  def act(_args, _context, state),
    do: {:error, Error.new("missing_arg", "act requires kind"), state}

  # ── the task ───────────────────────────────────────────────────────────────

  # Every check and request answers with the state it was made with, so a
  # failure keeps what the operation had already learnt.
  defp operate(context, state, fun) do
    case ensure_task(context, state) do
      {:ok, state} -> fun.(state)
      failure -> failure
    end
  end

  defp ensure_task(_context, %{lost: %Error{} = error} = state), do: {:reap, error, state}
  defp ensure_task(context, %{task: nil} = state), do: bind(context, state)
  defp ensure_task(_context, state), do: check_host(state)

  defp bind(context, state) do
    host = HostAvailability.current(state.host_availability)
    caller = Map.fetch!(context, :caller)

    if HostAvailability.usable?(host) do
      task = %{
        id: "task-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
        agent: Map.get(context, :agent_name, "browser"),
        connection: host.connection,
        connection_id: host.connection_id,
        connection_ref: Process.monitor(host.connection),
        caller: caller,
        caller_ref: Process.monitor(caller)
      }

      trace(task.agent, "browser_host_task_start", state, %{
        "task_id" => task.id,
        "connection" => task.connection_id
      })

      {:ok, %{state | task: task}}
    else
      error = lost_error(HostAvailability.unavailable_reason(host))
      :ok = TurnMarker.mark(state.turn_marker, state.owner_key, caller, error)
      {:reap, error, %{state | lost: error}}
    end
  end

  # The task runs on the connection it was bound to, while that host's last
  # report says the pane is available, and nowhere else.
  defp check_host(%{task: task} = state) do
    host = HostAvailability.current(state.host_availability)

    cond do
      host.connection != task.connection and host.attached ->
        lose(state, "its connection to the app was replaced")

      HostAvailability.usable?(host) and host.connection == task.connection ->
        {:ok, state}

      true ->
        lose(state, HostAvailability.unavailable_reason(host))
    end
  end

  # The task keeps its binding, so the profile's teardown still releases its
  # tabs on a connection that is up; one that is gone took them with it.
  defp lose(state, reason) do
    error = lost_error(reason)
    :ok = TurnMarker.mark(state.turn_marker, state.owner_key, state.task.caller, error)
    {:reap, error, %{state | lost: error}}
  end

  defp lost_error(reason) do
    reason = reason |> String.slice(0, @reason_chars) |> String.trim_trailing(".")
    Error.new("host_lost", "The Fermix app's browser is no longer available: #{reason}.")
  end

  # ── one request ────────────────────────────────────────────────────────────

  # The answer, the connection's end, or the app's quit, whichever comes
  # first. A timeout leaves the request to run: its late answer is dropped.
  defp request(%{task: task} = state, type, payload, timeout_ms) do
    ref = Link.request(task.connection, task.id, type, payload)
    connection = task.connection
    connection_ref = task.connection_ref

    receive do
      {:browser_host_answer, ^ref, {:ok, result}} -> {:ok, result, state}
      {:browser_host_answer, ^ref, {:error, error}} -> host_error(error, state)
      {:DOWN, ^connection_ref, :process, _pid, _reason} -> lose(state, "the app disconnected")
      {:browser_host_stopping, ^connection} -> lose(state, "the app is quitting")
    after
      timeout_ms -> {:error, timeout_error(type, timeout_ms), state}
    end
  end

  # The app reports its pane unavailable before it refuses work for that
  # reason, so the report is what the sentence says.
  defp host_error(%{"reason" => "host_unavailable", "message" => message}, state) do
    host = HostAvailability.current(state.host_availability)

    if HostAvailability.usable?(host),
      do: lose(state, message),
      else: lose(state, HostAvailability.unavailable_reason(host))
  end

  defp host_error(%{"reason" => reason, "message" => message}, state),
    do: {:error, Error.new(reason, host_sentence(reason, message), %{"app" => message}), state}

  defp host_sentence("stale_ref", _message), do: @stale_ref
  defp host_sentence("dialog_blocked", _message), do: @dialog_blocked

  defp host_sentence("tab_not_found", _message) do
    "That tab is not open in the Fermix app's browser any more. List the tabs with `tabs` " <>
      "and use one of those."
  end

  defp host_sentence("cap_reached", _message) do
    "The Fermix app's browser refused another tab: this task already has as many tabs open " <>
      "as it may. Close one it opened, or keep working in an open one."
  end

  defp host_sentence("not_owner", _message) do
    "That tab belongs to the person, not to this task, so it is not mine to drive."
  end

  defp host_sentence(_reason, message),
    do: "The Fermix app's browser could not do that: #{message}"

  defp timeout_error(type, timeout_ms) do
    Error.new(
      "host_timeout",
      "The Fermix app's browser did not answer #{type} within #{div(timeout_ms, 1_000)} " <>
        "seconds, so whether it happened is unknown. Take a snapshot before repeating it."
    )
  end

  defp action_timeout(state), do: state.config.action_timeout_ms

  defp navigation_timeout(config),
    do: config.navigation_timeout_ms + Config.act_limits().navigation_budget_ms

  defp act_timeout(%{"timeout_ms" => wait_ms}, _mark, config),
    do: wait_ms + config.action_timeout_ms

  defp act_timeout(_fields, nil, config), do: config.action_timeout_ms

  defp act_timeout(_fields, _mark, config),
    do: config.action_timeout_ms + Config.act_limits().settle_budget_ms

  # ── navigation ─────────────────────────────────────────────────────────────

  defp navigated({:ok, result, state}, observe?) do
    state = put_tab(result, state)
    public = public_id(state, result["tab_id"])

    with {:ok, state} <- navigation_verdict(result["url"], state) do
      tab_result = tab_result(state.tabs[public])
      observe_navigation(tab_result, result["page"], public, observe?, %{state | active: public})
    end
  end

  defp navigated(failure, _observe?), do: failure

  defp observe_navigation(result, _page, _public, false, state), do: {:ok, result, state}

  defp observe_navigation(result, nil, _public, true, state),
    do: {:ok, Map.put(result, "page", "unobserved"), state}

  defp observe_navigation(result, page, public, true, state) do
    mark = %{opts: fresh_options(state), hash: nil}
    {result, state} = observed(result, page, mark, public, state)
    {:ok, result, state}
  end

  # The address the app is about to be sent to, and the one it committed to:
  # the host rules, then, for a name, where its lookup says it points.
  defp navigation_verdict(url, state) do
    case Policy.validate_url(url, state.config) do
      {:ok, uri} -> resolved_verdict(uri, state)
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp resolved_verdict(uri, state) do
    case Policy.resolution_host(uri, state.config) do
      {:ok, host} -> answers_verdict(host, lookup(host, state))
      :none -> {:ok, state}
    end
  end

  defp answers_verdict(host, {answers, state}) do
    case Policy.answers_verdict(host, answers, state.config) do
      :ok -> {:ok, state}
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  # THE read gate for this backend: every page answer that hands back bytes
  # read from a page is judged on the address the app reports, which is the
  # web view's committed URL, never a value the page supplies.
  defp read_gate(url, state) do
    case Policy.read_verdict(url, state.config) do
      :ok -> read_answers_gate(url, read_answers(url, state))
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp read_answers_gate(url, {answers, state}) do
    case Policy.read_answers_verdict(url, answers, state.config) do
      :ok -> {:ok, state}
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp read_answers(url, state) do
    case Policy.resolution_host(URI.parse(url), state.config) do
      {:ok, host} -> lookup(host, state)
      :none -> {[], state}
    end
  end

  # Once per host for the life of the task, a failed lookup included; full
  # means cleared, not grown.
  defp lookup(host, %{resolved: resolved} = state) when is_map_key(resolved, host),
    do: {Map.fetch!(resolved, host), state}

  defp lookup(host, state) do
    answers =
      case state.resolver.(host) do
        {:ok, answers} when is_list(answers) -> answers
        {:error, _reason} -> []
      end

    kept =
      if map_size(state.resolved) >= Config.address_limits().resolved_hosts,
        do: %{},
        else: state.resolved

    {answers, %{state | resolved: Map.put(kept, host, answers)}}
  end

  # ── pages ──────────────────────────────────────────────────────────────────

  defp snapshot_options(args, state) do
    case Config.snapshot_options(args, state.config) do
      {:ok, opts} -> {:ok, opts}
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp fresh_options(state) do
    {:ok, opts} = Config.snapshot_options(%{}, state.config)
    opts
  end

  defp wire_options(opts) do
    %{
      "mode" => if(opts.interactive, do: "interactive", else: "full"),
      "max_chars" => opts.max_chars,
      "depth" => opts.depth
    }
  end

  defp observe_fields(payload, true, opts),
    do: Map.merge(payload, %{"observe" => true, "snapshot" => wire_options(opts)})

  defp observe_fields(payload, false, _opts), do: Map.put(payload, "observe", false)

  # The page the app handed back after a navigation or an action, judged and
  # rendered with the options of the look it is compared against. Identical
  # text means identical refs, so only the text is withheld when nothing
  # changed; the ref map is replaced either way.
  defp observed(result, page, mark, public, state) do
    case read_gate(page["url"], state) do
      {:ok, state} ->
        {:ok, rendered} = Snapshot.render(page["nodes"], mark.opts)
        state = state |> put_page(public, page) |> remember(public, mark.opts, rendered)
        {page_verdict(result, page, rendered, mark), state}

      {:error, %Error{} = error, state} ->
        {page_refused(result, error), state}
    end
  end

  defp page_verdict(result, page, rendered, mark) do
    result = Map.merge(result, %{"url" => page["url"], "ready_state" => page["ready_state"]})

    if :crypto.hash(:sha256, rendered.text) == mark.hash do
      Map.put(result, "page", "unchanged")
    else
      Map.merge(result, %{
        "page" => "changed",
        "snapshot" => rendered.text,
        "truncated" => rendered.truncated
      })
    end
  end

  defp page_refused(result, %Error{code: code} = error) do
    result
    |> Map.drop(["url", "title"])
    |> Map.merge(%{"page" => code, "page_reason" => error.message})
  end

  defp remember(state, public, opts, rendered) do
    refs = Map.new(rendered.refs, &{&1.ref, &1.backend_node_id})
    mark = %{opts: opts, hash: :crypto.hash(:sha256, rendered.text)}

    %{
      state
      | ref_maps: Map.put(state.ref_maps, public, refs),
        observations: Map.put(state.observations, public, mark)
    }
  end

  defp snapshot_result(public, page, rendered) do
    %{
      "ok" => true,
      "target" => public,
      "url" => page["url"],
      "title" => page["title"],
      "ready_state" => page["ready_state"],
      "snapshot" => rendered.text,
      "truncated" => rendered.truncated
    }
  end

  # ── tabs ───────────────────────────────────────────────────────────────────

  defp public_id(state, wire_id), do: "h#{state.task.connection_id}:#{wire_id}"

  defp put_tab(%{"tab_id" => wire} = result, state) do
    public = public_id(state, wire)
    tab = %{id: public, wire: wire, url: result["url"], title: result["title"]}
    %{state | tabs: Map.put(state.tabs, public, tab)}
  end

  defp put_page(state, public, page) do
    case Map.fetch(state.tabs, public) do
      {:ok, tab} ->
        tab = %{tab | url: page["url"], title: page["title"]}
        %{state | tabs: Map.put(state.tabs, public, tab)}

      :error ->
        state
    end
  end

  # The app's list is the task's whole tab set, popups included, so a tab it
  # no longer lists is gone.
  defp list_tabs(listed, state) do
    state = Enum.reduce(listed, %{state | tabs: %{}}, &put_tab/2)

    active =
      Enum.find_value(
        listed,
        state.active,
        &(&1["active"] == true && public_id(state, &1["tab_id"]))
      )

    kept = Map.keys(state.tabs)

    %{
      state
      | active: if(active in kept, do: active),
        ref_maps: Map.take(state.ref_maps, kept),
        observations: Map.take(state.observations, kept)
    }
  end

  defp sorted_tabs(state), do: state.tabs |> Map.values() |> Enum.sort_by(& &1.id)

  # A tab whose page the read gate refuses is listed by its id and the verdict,
  # never its address or title.
  defp tab_row(tab, state) do
    case read_gate(tab.url, state) do
      {:ok, state} ->
        {tab_result(tab), state}

      {:error, %Error{code: code}, state} ->
        {%{"id" => tab.id, "target" => tab.id, "page" => code}, state}
    end
  end

  defp tab_result(tab) do
    %{
      "id" => tab.id,
      "target" => tab.id,
      "url" => tab.url,
      "title" => tab.title,
      "type" => "page"
    }
  end

  defp resolve_tab(nil, %{active: nil} = state) do
    {:error,
     Error.new(
       "no_tab",
       "No tab is open in the Fermix app's browser for this task. Open one first."
     ), state}
  end

  defp resolve_tab(nil, state), do: {:ok, Map.fetch!(state.tabs, state.active)}

  defp resolve_tab(public, state) when is_binary(public) do
    case Map.fetch(state.tabs, public) do
      {:ok, tab} -> {:ok, tab}
      :error -> {:error, Error.new("tab_not_found", host_sentence("tab_not_found", "")), state}
    end
  end

  defp forget_tab(state, public) do
    %{
      state
      | tabs: Map.delete(state.tabs, public),
        active: if(state.active == public, do: nil, else: state.active),
        ref_maps: Map.delete(state.ref_maps, public),
        observations: Map.delete(state.observations, public),
        dialogs: Enum.reject(state.dialogs, &(&1["target"] == public))
    }
  end

  # ── the app's events ───────────────────────────────────────────────────────

  defp record_event("tab.closed", %{"tab_id" => wire}, state),
    do: forget_tab(state, public_id(state, wire))

  defp record_event("dialog.opened", %{"tab_id" => wire} = payload, state) do
    public = public_id(state, wire)

    if Map.has_key?(state.tabs, public) do
      dialog =
        payload
        |> Map.take(["kind", "message", "default"])
        |> Map.put("target", public)

      %{state | dialogs: Enum.take([dialog | state.dialogs], state.config.dialog_buffer_limit)}
    else
      state
    end
  end

  defp record_event("download.finished", %{"tab_id" => wire} = payload, state) do
    if Map.has_key?(state.tabs, public_id(state, wire)),
      do: %{state | downloads: Enum.take(state.downloads ++ [payload], -@download_buffer)},
      else: state
  end

  defp record_event(_type, _payload, state), do: state

  # ── act ────────────────────────────────────────────────────────────────────

  defp undialogged(tab, state) do
    if Enum.any?(state.dialogs, &(&1["target"] == tab.id)),
      do: {:error, Error.new("dialog_blocked", @dialog_blocked), state},
      else: :ok
  end

  defp act_fields(%{"kind" => kind} = args, tab, state) when kind in ~w(click hover submit) do
    with {:ok, ref} <- element_ref(tab, args["ref"], state), do: {:ok, %{"ref" => ref}}
  end

  defp act_fields(%{"kind" => kind} = args, tab, state) when kind in ~w(fill type) do
    with {:ok, ref} <- element_ref(tab, args["ref"], state),
         do: {:ok, %{"ref" => ref, "text" => args["text"]}}
  end

  defp act_fields(%{"kind" => "fill_form", "fields" => fields}, tab, state)
       when is_list(fields) do
    refs = Map.get(state.ref_maps, tab.id, %{})

    case Enum.reject(fields, &Map.has_key?(refs, Snapshot.ref_key(&1["ref"]))) do
      [] ->
        {:ok, %{"fields" => Enum.map(fields, &form_field(&1, refs))}}

      _unknown ->
        {:error, Error.new("stale_ref", "fill_form filled nothing. " <> @stale_ref), state}
    end
  end

  defp act_fields(%{"kind" => "press", "key" => key}, _tab, _state), do: {:ok, %{"key" => key}}

  defp act_fields(%{"kind" => "click_coords", "x" => x, "y" => y}, _tab, _state),
    do: {:ok, %{"x" => x, "y" => y}}

  defp act_fields(%{"kind" => "get"} = args, _tab, _state) do
    {:ok,
     %{"field" => Map.get(args, "field", "text")}
     |> put_present("selector", args["selector"])}
  end

  defp act_fields(%{"kind" => "wait"} = args, tab, state), do: wait_fields(args, tab, state)

  defp act_fields(%{"kind" => kind}, _tab, state),
    do: {:error, Error.new("invalid_action", "Unsupported act kind: #{inspect(kind)}"), state}

  defp wait_fields(args, tab, state) do
    config = state.config
    timeout = bounded(args["timeout_ms"], config.wait_default_ms, config.wait_max_ms)

    fields =
      %{"wait_until" => args["wait_until"], "timeout_ms" => timeout}
      |> put_present("text", args["text"])
      |> put_present("selector", args["selector"])

    case args["ref"] do
      nil ->
        {:ok, fields}

      ref ->
        with {:ok, host_ref} <- element_ref(tab, ref, state),
             do: {:ok, Map.put(fields, "ref", host_ref)}
    end
  end

  defp form_field(field, refs),
    do: %{"ref" => Map.fetch!(refs, Snapshot.ref_key(field["ref"])), "text" => field["text"]}

  defp element_ref(tab, ref, state) when is_binary(ref) do
    case get_in(state.ref_maps, [tab.id, Snapshot.ref_key(ref)]) do
      nil -> {:error, Error.new("stale_ref", @stale_ref), state}
      host_ref -> {:ok, host_ref}
    end
  end

  defp element_ref(_tab, _ref, state) do
    {:error, Error.new("invalid_arg", "`ref` must be an element ref from the latest snapshot."),
     state}
  end

  # A tab the model has looked at is looked at again after an action that can
  # restructure it; one it never snapshotted is left alone, as in Chrome.
  defp observation(kind, args, tab, state) do
    observing? = kind in @observing_kinds or (kind == "press" and args["key"] == "Enter")
    if observing?, do: Map.get(state.observations, tab.id)
  end

  defp acted({:ok, result, state}, kind, tab, mark) do
    state = put_page(state, tab.id, result)
    receipt = %{"ok" => true, "target" => tab.id, "action" => kind}
    act_receipt(kind, result, receipt, tab, mark, state)
  end

  defp acted(failure, _kind, _tab, _mark), do: failure

  # `get` hands back page text, so it faces the read gate like any read.
  defp act_receipt("get", result, receipt, _tab, _mark, state) do
    with {:ok, state} <- read_gate(result["url"], state) do
      {:ok, Map.put(receipt, "value", result["value"]), state}
    end
  end

  defp act_receipt(_kind, _result, receipt, _tab, nil, state), do: {:ok, receipt, state}

  defp act_receipt(_kind, %{"page" => page}, receipt, tab, mark, state) do
    {receipt, state} = observed(receipt, page, mark, tab.id, state)
    {:ok, receipt, state}
  end

  defp act_receipt(_kind, _result, receipt, _tab, _mark, state),
    do: {:ok, Map.put(receipt, "page", "unobserved"), state}

  # ── artifacts and downloads ────────────────────────────────────────────────

  # The engine names the file inside the workspace and the app writes exactly
  # there. The page is judged on the address the app reports: a page the read
  # gate refuses leaves nothing on disk.
  defp capture(args, context, state, type, {kind, extension}) do
    operate(context, state, fn state ->
      with {:ok, tab} <- resolve_tab(args["target"], state),
           {:ok, dir} <- ensure_dir(artifact_dir(state, kind), state) do
        capture_at(state, tab, type, dir, extension, args)
      end
    end)
  end

  defp capture_at(state, tab, type, dir, extension, args) do
    path = Path.join(dir, "#{System.unique_integer([:positive, :monotonic])}.#{extension}")
    payload = capture_payload(type, tab, path, args)

    with {:ok, result, state} <- request(state, type, payload, action_timeout(state)) do
      captured(result, {type, path}, tab, state)
    end
  end

  defp capture_payload("page.screenshot", tab, path, args),
    do: %{"tab_id" => tab.wire, "path" => path, "full_page" => Map.get(args, "full_page") == true}

  defp capture_payload("page.pdf", tab, path, _args), do: %{"tab_id" => tab.wire, "path" => path}

  defp captured(%{"path" => path} = result, {type, path}, tab, state) do
    case read_gate(result["url"], state) do
      {:ok, state} ->
        within_size(type, result, tab, state)

      {:error, %Error{} = error, state} ->
        _ = File.rm(path)
        {:error, error, state}
    end
  end

  defp captured(result, {_type, path}, _tab, state) do
    Logger.warning("browser host wrote #{inspect(result["path"])} instead of #{path}")

    {:error, Error.new("artifact_write_failed", "The Fermix app wrote the capture elsewhere."),
     state}
  end

  defp within_size("page.screenshot", %{"bytes" => bytes} = result, _tab, state)
       when bytes > state.config.screenshot_max_bytes do
    _ = File.rm(result["path"])
    max = state.config.screenshot_max_bytes

    {:error,
     Error.new(
       "screenshot_too_large",
       "Screenshot exceeded #{max} bytes; use a viewport capture",
       %{"bytes" => bytes}
     ), state}
  end

  defp within_size(_type, result, tab, state) do
    artifact = Map.take(result, ["path", "mime_type", "device_pixel_ratio"])
    {:ok, Map.merge(artifact, %{"ok" => true, "target" => tab.id}), state}
  end

  defp await_download(%{downloads: [download | rest]} = state, _deadline),
    do: download_reply(download, %{state | downloads: rest})

  # Only a finished download is taken out of the mailbox; the app's other
  # events wait for the server's own turn at them.
  defp await_download(%{task: task} = state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    connection = task.connection
    connection_ref = task.connection_ref

    receive do
      {:browser_host_event, ^connection, "download.finished", payload} ->
        "download.finished" |> record_event(payload, state) |> await_download(deadline)

      {:DOWN, ^connection_ref, :process, _pid, _reason} ->
        lose(state, "the app disconnected")

      {:browser_host_stopping, ^connection} ->
        lose(state, "the app is quitting")
    after
      remaining -> {:error, Error.new("timeout", "download timed out"), state}
    end
  end

  defp download_reply(%{"state" => "completed", "path" => path} = download, state) do
    if String.starts_with?(path, download_dir(state) <> "/") do
      {:ok, %{"ok" => true, "download" => download_view(download)}, state}
    else
      {:error, Error.new("download_failed", "The Fermix app saved the download elsewhere."),
       state}
    end
  end

  defp download_reply(download, state) do
    reason = Map.get(download, "reason", download["state"])
    {:error, Error.new("download_failed", "The download did not finish: #{reason}."), state}
  end

  defp download_view(download) do
    %{
      "guid" => download["download_id"],
      "path" => download["path"],
      "bytes" => download["bytes"],
      "state" => download["state"]
    }
  end

  defp artifact_dir(state, kind) do
    Path.join([ConfigStore.workspace_paths().browser, "artifacts", state.owner_key, kind])
  end

  defp download_dir(state) do
    Path.join([ConfigStore.workspace_paths().browser, "downloads", state.owner_key])
  end

  defp ensure_dir(dir, state) do
    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, Error.new("artifact_write_failed", inspect(reason)), state}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp dialog_tab(nil, %{dialogs: [%{"target" => public} | _rest]} = state),
    do: resolve_tab(public, state)

  defp dialog_tab(target, state), do: resolve_tab(target, state)

  defp dialog_payload(tab, decision, text) do
    %{"tab_id" => tab.wire, "accept" => decision == "accept"}
    |> put_present("text", text)
  end

  defp upload_path(path, state) do
    case Upload.confined_path(path) do
      {:ok, path} -> {:ok, path}
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp refuse(capability, state) do
    {:error, error} = Capabilities.refuse(:fermix_app, capability)
    {:error, error, state}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp bounded(value, _default, max) when is_integer(value) and value > 0, do: min(value, max)
  defp bounded(_value, default, _max), do: default

  defp trace(agent, event, state, data) do
    data =
      Map.merge(data, %{
        "event" => event,
        "profile" => state.profile_name,
        "owner" => state.owner_key
      })

    Trace.record(:agent_event, agent, data)
  end
end
