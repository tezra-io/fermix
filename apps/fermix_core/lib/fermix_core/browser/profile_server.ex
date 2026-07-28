defmodule FermixCore.Browser.ProfileServer do
  @moduledoc """
  Owns one managed Chrome instance for a single `{owner, profile}` scope.

  Lifecycle is lazy and self-bounded: Chrome launches on the first request,
  repeated launch failures enter a config-driven cooldown, and the server
  self-stops after `idle_profile_ttl_ms` of inactivity. `terminate/2` guarantees
  Chrome teardown on every exit path (idle, eviction, shutdown, crash), so no
  Chrome process is ever orphaned.

  Tabs are bounded too: each `open` spawns a new CDP target, so without a cap a
  long session would accumulate tabs (they outlive any single action) and grow
  Chrome's memory unbounded. `enforce_tab_cap/1` closes the oldest non-active
  tabs back to `max_tabs` after each `open`, for managed profiles only — a
  user-attached Chrome's own tabs are never closed.

  Callers reach this process directly (via the registry); the manager only
  starts/evicts it. Requests are serialized per scope by the GenServer.
  """

  use GenServer

  alias FermixCore.Browser.CDP.Connection
  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.Policy
  alias FermixCore.Browser.Snapshot
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Telemetry
  alias FermixCore.Trace

  require Logger

  @page_types ~w(page webview)
  @advanced_actions ~w(focus close screenshot pdf console dialog cookies storage upload download act)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case via(opts) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec status(GenServer.server()) :: map()
  def status(pid), do: GenServer.call(pid, :status)

  @spec request(GenServer.server(), map()) :: {:ok, map()} | {:error, Error.t()}
  def request(pid, request), do: GenServer.call(pid, {:request, request}, :infinity)

  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(pid, timeout) do
    GenServer.stop(pid, :normal, timeout)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      owner_key: Keyword.fetch!(opts, :owner_key),
      profile_name: Keyword.fetch!(opts, :profile_name),
      profile: Keyword.fetch!(opts, :profile),
      config: Keyword.fetch!(opts, :config),
      registry: Keyword.get(opts, :registry),
      key: Keyword.get(opts, :key),
      launcher: Keyword.get(opts, :launcher, ChromeLauncher),
      conn_mod: Keyword.get(opts, :connection, Connection),
      now_fn: Keyword.get(opts, :now_fn, fn -> System.monotonic_time(:millisecond) end),
      runtime: nil,
      targets: %{},
      active_target: nil,
      tab_order: [],
      ref_maps: %{},
      console: [],
      dialogs: [],
      downloads: %{},
      reported_downloads: MapSet.new(),
      launch_failures: 0,
      cooldown_until: nil,
      idle_ref: nil
    }

    {:ok, schedule_idle(state)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call({:request, request}, _from, state) do
    {reply, state} = run_request(request, touch_idle(state))
    {:reply, attach_console(reply, state), state}
  end

  # A failed action carries the recent console/JS-exception buffer (oldest
  # first, same order as the explicit `console` action) in its error details —
  # page-side context is often the only clue to why a click/fill/navigate
  # failed. Gated behind content capture so regular error details stay
  # body-free. Entry COUNT is capped by `console_buffer_limit`; entry size is
  # not — capture-on is full-fidelity by design.
  defp attach_console({:error, %Error{} = error}, %{console: [_ | _] = console}) do
    if Telemetry.capture_content?() do
      {:error, %{error | details: Map.put(error.details, "console", Enum.reverse(console))}}
    else
      {:error, error}
    end
  end

  defp attach_console(reply, _state), do: reply

  @impl true
  def handle_info(:idle_timeout, state), do: {:stop, :normal, state}

  def handle_info({:cdp_event, method, event}, state) do
    {:noreply, record_event(method, event, state)}
  end

  def handle_info({_port, {:data, _data}}, state), do: {:noreply, state}

  def handle_info({_port, {:exit_status, status}}, state) do
    state = %{stop_runtime(state) | console: crash_entry(status, state)}
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, _reason}, %{runtime: %{connection: pid}} = state) do
    Logger.debug("browser: CDP connection exited for profile #{state.profile_name}")
    {:noreply, stop_runtime(state)}
  end

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_runtime(state)
    :ok
  end

  defp run_request(%{action: "status"}, state), do: {{:ok, status_map(state)}, state}

  defp run_request(%{action: "stop"}, state) do
    {{:ok, %{"ok" => true, "stopped" => true}}, stop_runtime(state)}
  end

  defp run_request(%{action: "start", context: context}, state) do
    with_running(state, context, fn state -> {{:ok, status_map(state)}, state} end)
  end

  defp run_request(%{action: "open", args: args, context: context}, state) do
    case Policy.validate_url(args["url"], state.config) do
      {:ok, uri} -> with_running(state, context, fn s -> finish(create_tab(uri, s), s) end)
      {:error, error} -> {{:error, error}, state}
    end
  end

  defp run_request(%{action: "navigate", args: args, context: context}, state) do
    case Policy.validate_url(args["url"], state.config) do
      {:ok, uri} ->
        with_running(state, context, fn s -> finish(navigate_chain(uri, args, s), s) end)

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  defp run_request(%{action: "snapshot", args: args, context: context}, state) do
    case Config.snapshot_options(args, state.config) do
      {:ok, opts} ->
        with_running(state, context, fn s -> finish(snapshot_chain(opts, args, s), s) end)

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  defp run_request(%{action: "tabs", context: context}, state) do
    with_running(state, context, fn s ->
      case refresh_targets(s) do
        {:ok, s} -> {{:ok, %{"ok" => true, "tabs" => tab_values(s)}}, s}
        {:error, error} -> {{:error, error}, s}
      end
    end)
  end

  defp run_request(%{action: action, args: args, context: context}, state)
       when action in @advanced_actions do
    with_running(state, context, fn s -> finish(run_advanced(action, args, s), s) end)
  end

  defp with_running(state, context, fun) do
    case ensure_running(state, context) do
      {:ok, state} -> fun.(state)
      {:error, error, state} -> {{:error, error}, state}
    end
  end

  defp finish({:ok, result, state}, _fallback), do: {{:ok, result}, state}
  defp finish({:error, %Error{} = error}, fallback), do: {{:error, error}, fallback}

  defp ensure_running(%{runtime: %{connection: pid}} = state, _context) when is_pid(pid) do
    {:ok, state}
  end

  # Re-attach to an already-running managed Chrome for this profile before
  # considering a spawn. This is what prevents the "Opening in existing browser
  # session" failure: a leftover Chrome (daemon restart, prior crash, hard kill)
  # holds the user-data-dir, so spawning a second one fails — reuse it instead.
  # Reuse bypasses the cooldown gate (it is not a spawn) and clears any cooldown.
  #
  # cooldown_until is nil when there is no active cooldown. A plain 0 sentinel
  # would be wrong because System.monotonic_time can be negative, which would
  # make `now < 0` look like an active cooldown before any failure.
  defp ensure_running(state, context) do
    case reattach(state, context) do
      {:ok, state} -> {:ok, state}
      :none -> launch_or_cooldown(state, context)
    end
  end

  defp reattach(state, context) do
    with {:ok, runtime} <-
           state.launcher.attach(state.config, state.profile, state.owner_key, state.profile_name),
         {:ok, state} <- finish_runtime(runtime, state) do
      emit(context, "browser_attach_existing", state, %{"cdp_port" => runtime.port})
      {:ok, %{state | launch_failures: 0, cooldown_until: nil}}
    else
      _other -> :none
    end
  end

  defp launch_or_cooldown(state, context) do
    now = state.now_fn.()

    if cooling_down?(state, now) do
      {:error, cooldown_error(state, now), state}
    else
      launch(state, context, now)
    end
  end

  defp cooling_down?(%{cooldown_until: until}, now), do: is_integer(until) and now < until

  defp launch(state, context, now) do
    emit(context, "browser_launch_start", state, %{})

    case start_runtime(state) do
      {:ok, state} ->
        emit(context, "browser_launch_ready", state, %{})
        {:ok, %{state | launch_failures: 0, cooldown_until: nil}}

      {:error, error} ->
        state = register_failure(state, now)

        emit(
          context,
          failure_event(state, now),
          state,
          Map.put(error.details, "error", error.code)
        )

        {:error, error, state}
    end
  end

  defp register_failure(state, now) do
    failures = state.launch_failures + 1
    config = state.config

    cooldown_until =
      if failures >= config.start_failure_threshold do
        now + cooldown_ms(failures, config)
      else
        nil
      end

    %{state | launch_failures: failures, cooldown_until: cooldown_until}
  end

  defp cooldown_ms(failures, config) do
    extra = failures - config.start_failure_threshold
    min(config.start_cooldown_ms * Integer.pow(2, extra), config.start_cooldown_max_ms)
  end

  defp failure_event(state, now),
    do:
      if(cooling_down?(state, now), do: "browser_launch_cooldown", else: "browser_launch_failed")

  defp cooldown_error(state, now) do
    Error.new(
      "browser_cooldown",
      "Browser launch is cooling down after repeated failures",
      %{"retry_in_ms" => state.cooldown_until - now}
    )
  end

  defp start_runtime(%{profile: %{mode: :managed}} = state) do
    case state.launcher.start(state.config, state.profile, state.owner_key, state.profile_name) do
      {:ok, runtime} -> finish_runtime(runtime, state)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp start_runtime(%{profile: %{cdp_url: url}} = state) when is_binary(url) do
    finish_runtime(%{ws_url: url, headless: nil, port: nil, os_pid: nil}, state)
  end

  defp start_runtime(_state) do
    {:error, Error.new("profile_unavailable", "Profile requires a configured CDP URL")}
  end

  # Connect to the just-spawned (or attached) browser and finish setup. If any
  # step after a managed launch fails, tear the runtime down HERE — the with
  # chain's local state would otherwise be discarded with Chrome still alive,
  # orphaning the process and leaking the CDP port.
  defp finish_runtime(runtime, state) do
    case connect(runtime.ws_url, state.config, state.conn_mod) do
      {:ok, connection} ->
        ready = %{state | runtime: Map.put(runtime, :connection, connection)}

        case configure_and_refresh(ready) do
          {:ok, ready} ->
            {:ok, ready}

          {:error, error} ->
            teardown_runtime(ready.runtime, state)
            {:error, error}
        end

      {:error, error} ->
        teardown_runtime(runtime, state)
        {:error, error}
    end
  end

  defp configure_and_refresh(state) do
    with {:ok, state} <- configure_downloads(state),
         {:ok, state} <- refresh_targets(state) do
      {:ok, state}
    end
  end

  # Reap a partially-started runtime: close the CDP connection (if any) and kill
  # the spawned Chrome via the launcher (a no-op for attach-only profiles whose
  # os_pid/port_ref are nil, so a user's own Chrome is never killed).
  defp teardown_runtime(runtime, state) do
    close_connection(runtime, state.conn_mod)
    state.launcher.stop(runtime, state.config)
    :ok
  end

  defp connect(url, config, conn_mod) do
    case conn_mod.start_link(url, owner: self(), keepalive_ms: config.cdp_keepalive_ms) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error,
         Error.new(
           "cdp_connect_failed",
           "Could not connect to the browser CDP endpoint: #{inspect(reason)}"
         )}
    end
  end

  defp create_tab(uri, state) do
    params = %{url: URI.to_string(uri)}

    with {:ok, %{"targetId" => target_id}} <- command(state, "Target.createTarget", params),
         {:ok, state} <- refresh_targets(%{state | active_target: tab_id(target_id)}),
         {:ok, tab, state} <- resolve_tab(tab_id(target_id), state),
         {:ok, state} <- enforce_tab_cap(state) do
      {:ok, tab_result(tab), state}
    end
  end

  # Keep a managed Chrome from accumulating tabs across a session: after an
  # `open` pushes the live count past `max_tabs`, close the oldest non-active
  # tabs back to the cap. Managed-only — a user-attached Chrome (cdp_url
  # profile) keeps all of its own tabs.
  defp enforce_tab_cap(state) do
    cap = state.config.max_tabs
    excess = map_size(state.targets) - cap

    if managed?(state) and excess > 0 do
      evict_oldest_tabs(state, excess)
    else
      {:ok, state}
    end
  end

  defp evict_oldest_tabs(state, excess) do
    victims =
      state.tab_order
      |> Enum.reject(&(&1 == state.active_target))
      |> Enum.take(excess)

    state = Enum.reduce(victims, state, &close_evicted_tab/2)
    refresh_targets(state)
  end

  # Best-effort: eviction is housekeeping for the just-served `open`, so a failed
  # close is logged (never swallowed) and the open still succeeds — the next
  # open re-attempts the trim.
  defp close_evicted_tab(tab_id, state) do
    case Map.fetch(state.targets, tab_id) do
      {:ok, tab} -> close_target(tab, state)
      :error -> state
    end
  end

  defp close_target(tab, state) do
    case command(state, "Target.closeTarget", %{targetId: tab.target_id}) do
      {:ok, _result} ->
        Logger.debug("browser: closed tab #{tab.id} to stay within max_tabs")
        state

      {:error, error} ->
        Logger.warning("browser: tab-cap eviction failed for #{tab.id}: #{inspect(error)}")
        state
    end
  end

  defp managed?(state), do: Map.get(state.profile, :mode) == :managed

  defp navigate_chain(uri, args, state) do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, result, state} <- navigate_tab(tab, uri, state) do
      {:ok, result, state}
    end
  end

  defp navigate_tab(tab, uri, state) do
    requested = URI.to_string(uri)

    with {:ok, tab, state} <- attach(tab, state),
         {:ok, _} <- command(state, "Page.enable", %{}, tab.session_id),
         {:ok, _} <-
           command(
             state,
             "Page.navigate",
             %{url: requested},
             tab.session_id,
             state.config.navigation_timeout_ms
           ),
         {:ok, final_url} <- committed_url(tab, requested, state),
         :ok <- final_url_allowed(final_url, state.config),
         {:ok, state} <- refresh_targets(state),
         {:ok, tab, state} <- resolve_tab(tab.id, state) do
      {:ok, tab_result(%{tab | url: final_url}), state}
    end
  end

  # The post-navigation final-URL check (redirect SSRF guard) must read the
  # COMMITTED document URL, not Target.getTargets — Page.navigate returns once
  # navigation is initiated, so getTargets still shows the stale/empty
  # pre-commit URL and validating "" wrongly fails as "missing scheme". Reading
  # location.href reflects the committed URL once the navigation commits; if it
  # is not yet available, fall back to the already-validated requested URL.
  defp committed_url(tab, requested, state) do
    case evaluate(tab, "location.href", state) do
      {:ok, result} ->
        case runtime_value(result) do
          url when is_binary(url) and url not in ["", "about:blank"] -> {:ok, url}
          _other -> {:ok, requested}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp snapshot_chain(opts, args, state) do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, result, state} <- snapshot_tab(tab, opts, state) do
      {:ok, result, state}
    end
  end

  # The Accessibility domain is CYCLED (disable → enable) so getFullAXTree is
  # built from the CURRENT document: Chrome otherwise serves the domain's cached
  # tree, which lags a navigation or SPA swap. Observed live (2026-07-26): a
  # snapshot 4s after lichess navigated to the created game returned the
  # HOMEPAGE tree under the live game url — the model went element-blind at the
  # exact moment its game began. Same family as `live_meta/2` below, which
  # already distrusts the cached url/title.
  defp snapshot_tab(tab, opts, state) do
    with {:ok, tab, state} <- attach(tab, state),
         {:ok, _} <- command(state, "Accessibility.disable", %{}, tab.session_id),
         {:ok, _} <- command(state, "Accessibility.enable", %{}, tab.session_id),
         {:ok, %{"nodes" => nodes}} <-
           command(state, "Accessibility.getFullAXTree", %{}, tab.session_id),
         {:ok, rendered} <- Snapshot.render(nodes, opts) do
      refs = Map.new(rendered.refs, &{&1.ref, &1})
      state = put_in(state.ref_maps[tab.id], refs)
      {:ok, snapshot_result(live_meta(tab, state), rendered), state}
    end
  end

  # The snapshot's AX content is read live, so its url/title must be live too —
  # the cached Target.getTargets values lag a client-side/redirect navigation,
  # which is why a snapshot could show fresh content under a stale url/title.
  defp live_meta(tab, state) do
    expression =
      "({url: document.location.href, title: document.title, ready: document.readyState})"

    case evaluate(tab, expression, state) do
      {:ok, result} ->
        case runtime_value(result) do
          %{"url" => url, "title" => title} = meta when is_binary(url) ->
            %{tab | url: url, title: title || tab.title}
            |> Map.put(:ready_state, Map.get(meta, "ready"))

          _other ->
            tab
        end

      {:error, _reason} ->
        tab
    end
  end

  defp run_advanced("act", _args, %{dialogs: [_dialog | _rest]}) do
    {:error,
     Error.new(
       "dialog_blocked",
       "A JavaScript dialog is blocking browser actions. Clear it first with the " <>
         "`dialog` action (`decision`: \"accept\" or \"dismiss\"), then retry this action."
     )}
  end

  defp run_advanced("upload", _args, %{dialogs: [_dialog | _rest]}) do
    {:error,
     Error.new(
       "dialog_blocked",
       "A JavaScript dialog is blocking browser actions. Clear it first with the " <>
         "`dialog` action (`decision`: \"accept\" or \"dismiss\"), then retry this action."
     )}
  end

  defp run_advanced("focus", args, state) do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, _} <- command(state, "Target.activateTarget", %{targetId: tab.target_id}) do
      {:ok, tab_result(tab), %{state | active_target: tab.id}}
    end
  end

  defp run_advanced("close", args, state) do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, _} <- command(state, "Target.closeTarget", %{targetId: tab.target_id}),
         {:ok, state} <- refresh_targets(%{state | active_target: nil}) do
      {:ok, %{"ok" => true, "closed" => tab.id}, state}
    end
  end

  defp run_advanced("screenshot", args, state), do: capture_screenshot(args, state)
  defp run_advanced("pdf", args, state), do: print_pdf(args, state)

  defp run_advanced("console", _args, state),
    do: {:ok, %{"ok" => true, "entries" => Enum.reverse(state.console)}, state}

  defp run_advanced("dialog", args, state), do: handle_dialog(args, state)
  defp run_advanced("cookies", args, state), do: handle_cookies(args, state)
  defp run_advanced("storage", args, state), do: handle_storage(args, state)
  defp run_advanced("upload", args, state), do: upload_file(args, state)
  defp run_advanced("download", args, state), do: wait_download(args, state)
  defp run_advanced("act", args, state), do: handle_act(args, state)

  defp capture_screenshot(args, state) do
    format = screenshot_format(Map.get(args, "format", "png"))
    params = screenshot_params(args, format)
    extension = if format == "jpeg", do: "jpg", else: "png"

    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, params} <- full_page_params(args, params, tab, state),
         {:ok, %{"data" => data}} <-
           command(state, "Page.captureScreenshot", params, tab.session_id),
         {:ok, bytes} <- decode_artifact(data),
         :ok <- within_size(bytes, state.config),
         {:ok, path} <- write_artifact(state, "screenshots", extension, bytes),
         {:ok, dpr_result} <- evaluate(tab, "window.devicePixelRatio", state) do
      result = %{
        "ok" => true,
        "target" => tab.id,
        "path" => path,
        "mime_type" => "image/#{format}",
        # The capture is DEVICE pixels (fromSurface); page coordinates
        # (`click_coords`, `get field=rect`) are CSS pixels. This ratio converts:
        # on a 2x display a point read off this image must be halved.
        "device_pixel_ratio" => runtime_value(dpr_result)
      }

      {:ok, result, state}
    end
  end

  defp print_pdf(args, state) do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, %{"data" => data}} <- command(state, "Page.printToPDF", %{}, tab.session_id),
         {:ok, bytes} <- decode_artifact(data),
         {:ok, path} <- write_artifact(state, "pdf", "pdf", bytes) do
      {:ok, %{"ok" => true, "target" => tab.id, "path" => path, "mime_type" => "application/pdf"},
       state}
    end
  end

  defp within_size(bytes, %Config{} = config) do
    if byte_size(bytes) <= config.screenshot_max_bytes do
      :ok
    else
      {:error,
       Error.new(
         "screenshot_too_large",
         "Screenshot exceeded #{config.screenshot_max_bytes} bytes; use a viewport capture or jpeg format",
         %{"bytes" => byte_size(bytes)}
       )}
    end
  end

  defp screenshot_format("jpeg"), do: "jpeg"
  defp screenshot_format("png"), do: "png"
  defp screenshot_format(_format), do: "png"

  defp screenshot_params(args, format) do
    params = %{
      format: format,
      fromSurface: true,
      captureBeyondViewport: Map.get(args, "full_page", false)
    }

    if format == "jpeg" and is_integer(args["quality"]) do
      Map.put(params, :quality, min(max(args["quality"], 1), 100))
    else
      params
    end
  end

  defp full_page_params(%{"full_page" => true}, params, tab, state) do
    with {:ok, %{"contentSize" => size}} <-
           command(state, "Page.getLayoutMetrics", %{}, tab.session_id) do
      max_side = state.config.screenshot_max_side_px

      clip = %{
        x: 0,
        y: 0,
        width: min(size["width"], max_side),
        height: min(size["height"], max_side),
        scale: 1
      }

      {:ok, Map.put(params, :clip, clip)}
    end
  end

  defp full_page_params(_args, params, _tab, _state), do: {:ok, params}

  defp decode_artifact(data) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, Error.new("artifact_decode_failed", "Browser artifact data was invalid")}
    end
  end

  defp handle_dialog(%{"decision" => decision} = args, state)
       when decision in ["accept", "dismiss"] do
    accept? = decision == "accept"
    params = %{accept: accept?, promptText: Map.get(args, "text", "")}

    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, _} <- command(state, "Page.handleJavaScriptDialog", params, tab.session_id) do
      {:ok, %{"ok" => true, "dialog" => decision}, %{state | dialogs: []}}
    end
  end

  defp handle_dialog(_args, state) do
    {:ok, %{"ok" => true, "dialogs" => Enum.reverse(state.dialogs)}, state}
  end

  defp handle_cookies(%{"kind" => "clear"}, state) do
    with {:ok, _} <- command(state, "Network.clearBrowserCookies", %{}) do
      {:ok, %{"ok" => true, "cleared" => true}, state}
    end
  end

  defp handle_cookies(_args, state) do
    with {:ok, %{"cookies" => cookies}} <- command(state, "Network.getAllCookies", %{}) do
      {:ok, %{"ok" => true, "cookies" => Enum.map(cookies, &redact_cookie/1)}, state}
    end
  end

  # Never surface cookie values to the model or traces — they include session
  # and auth tokens. Return only non-secret metadata.
  defp redact_cookie(cookie) when is_map(cookie) do
    Map.take(cookie, [
      "name",
      "domain",
      "path",
      "secure",
      "httpOnly",
      "sameSite",
      "expires",
      "session",
      "size"
    ])
  end

  defp handle_storage(args, state) do
    store = Map.get(args, "kind", "local")
    expression = storage_expression(store, Map.get(args, "key"), Map.get(args, "value"))

    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, result} <- evaluate(tab, expression, state) do
      {:ok, %{"ok" => true, "result" => runtime_value(result)}, state}
    end
  end

  defp upload_file(args, state) do
    with {:ok, path} <- confined_upload_path(args["path"]),
         {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, ref_data} <- ref_data(tab, args["ref"], state),
         params <- %{backendNodeId: ref_data.backend_node_id, files: [path]},
         {:ok, _} <- command(state, "DOM.setFileInputFiles", params, tab.session_id) do
      {:ok, %{"ok" => true, "target" => tab.id, "uploaded" => Path.basename(path)}, state}
    end
  end

  defp wait_download(args, state) do
    config = state.config

    timeout =
      bounded(Map.get(args, "timeout_ms"), config.download_default_ms, config.download_max_ms)

    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_download(state, deadline)
  end

  defp handle_act(%{"kind" => "click_coords"} = args, state) do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         :ok <- mouse_click(state, tab.session_id, args["x"], args["y"]),
         {:ok, state} <- refresh_targets(state),
         {:ok, url_result} <- evaluate(tab, "location.href", state) do
      result = %{
        "ok" => true,
        "target" => tab.id,
        "action" => "click_coords",
        # The same receipt ref clicks carry: the model confirms a navigation (or
        # its absence) from the result instead of taking another look.
        "url" => runtime_value(url_result),
        "tabs" => tab_values(state)
      }

      {:ok, result, state}
    end
  end

  defp handle_act(%{"kind" => kind, "ref" => ref} = args, state)
       when kind in ["click", "fill", "type", "hover", "submit"] do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, box} <- ref_box(tab, ref, state),
         {:ok, result} <- run_ref_action(kind, args, tab, box, state),
         {:ok, state} <- refresh_targets(state) do
      result = Map.put(result, "tabs", tab_values(state))
      {:ok, result, state}
    end
  end

  defp handle_act(%{"kind" => "press", "key" => key} = args, state) when is_binary(key) do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, _} <- key_event(state, tab.session_id, key),
         {:ok, state} <- refresh_targets(state) do
      result = %{
        "ok" => true,
        "target" => tab.id,
        "action" => "press",
        "tabs" => tab_values(state)
      }

      {:ok, result, state}
    end
  end

  defp handle_act(%{"kind" => "get"} = args, state), do: handle_get(args, state)
  defp handle_act(%{"kind" => "wait"} = args, state), do: wait_for(args, state)

  defp handle_act(args, _state),
    do: {:error, Error.new("invalid_action", "Unsupported act kind: #{inspect(args["kind"])}")}

  defp run_ref_action("click", _args, tab, box, state) do
    with :ok <- mouse_click(state, tab.session_id, box.x, box.y) do
      result = %{"ok" => true, "target" => tab.id, "action" => "click"}
      {:ok, Map.merge(result, url_receipt(state, tab))}
    end
  end

  defp run_ref_action("hover", _args, tab, box, state) do
    with {:ok, _} <- mouse_event(state, tab.session_id, "mouseMoved", box.x, box.y) do
      {:ok, %{"ok" => true, "target" => tab.id, "action" => "hover"}}
    end
  end

  # `fill` REPLACES the field: click it, clear the value on the resolved node
  # (set `.value=""` / `.textContent=""` and fire input+change so framework-
  # controlled inputs update), then insert the text. This is the fix for the
  # `Rome` -> `RomeAmsterdam` append bug — the old keystroke select-all used
  # `modifiers: 6` (Ctrl+Shift, not Ctrl) and never cleared.
  defp run_ref_action("fill", args, tab, box, state) do
    with :ok <- mouse_click(state, tab.session_id, box.x, box.y),
         {:ok, ref_data} <- ref_data(tab, args["ref"], state),
         :ok <- clear_field(state, tab.session_id, ref_data.backend_node_id),
         {:ok, _} <- command(state, "Input.insertText", %{text: args["text"]}, tab.session_id) do
      result = %{"ok" => true, "target" => tab.id, "action" => "fill"}
      {:ok, Map.merge(result, value_receipt(state, tab, ref_data))}
    end
  end

  # `type` APPENDS at the cursor (use only to add to existing content, e.g. to
  # trigger typeahead/autocomplete on a field that already holds a value).
  defp run_ref_action("type", args, tab, box, state) do
    with :ok <- mouse_click(state, tab.session_id, box.x, box.y),
         {:ok, ref_data} <- ref_data(tab, args["ref"], state),
         {:ok, _} <- command(state, "Input.insertText", %{text: args["text"]}, tab.session_id) do
      result = %{"ok" => true, "target" => tab.id, "action" => "type"}
      {:ok, Map.merge(result, value_receipt(state, tab, ref_data))}
    end
  end

  # `submit` completes a form: find the form owning the ref and click its primary
  # control (Search / Go / Submit), so a filled-but-unsubmitted form can't be
  # mistaken for a finished task. Returns the clicked label + the resulting url.
  defp run_ref_action("submit", args, tab, _box, state) do
    with {:ok, ref_data} <- ref_data(tab, args["ref"], state),
         {:ok, label} <- click_primary_submit(state, tab.session_id, ref_data.backend_node_id) do
      result = %{"ok" => true, "target" => tab.id, "action" => "submit", "submitted" => label}
      {:ok, Map.merge(result, url_receipt(state, tab))}
    end
  end

  @clear_field_js """
  function() {
    if (this.isContentEditable) { this.textContent = ''; }
    else { this.value = ''; }
    this.dispatchEvent(new Event('input', { bubbles: true }));
    this.dispatchEvent(new Event('change', { bubbles: true }));
  }
  """

  defp clear_field(state, session_id, backend_node_id) do
    with {:ok, %{"object" => %{"objectId" => object_id}}} <-
           command(state, "DOM.resolveNode", %{backendNodeId: backend_node_id}, session_id),
         {:ok, _} <-
           command(
             state,
             "Runtime.callFunctionOn",
             %{objectId: object_id, functionDeclaration: @clear_field_js, returnByValue: true},
             session_id
           ) do
      :ok
    end
  end

  @read_value_js """
  function() {
    if (this.isContentEditable) { return this.textContent; }
    return this.value;
  }
  """

  # Best-effort post-action receipts so the agent verifies a result without a
  # blind re-snapshot. Reads target the EXACT node (not document.activeElement,
  # which a page can steal). A read failure is logged (never swallowed) and the
  # field is simply omitted from the receipt.
  defp value_receipt(state, tab, ref_data) do
    receipt(%{}, "value", node_value(state, tab.session_id, ref_data.backend_node_id))
  end

  defp url_receipt(state, tab) do
    receipt(%{}, "url", url_value(state, tab))
  end

  defp node_value(state, session_id, backend_node_id) do
    with {:ok, %{"object" => %{"objectId" => object_id}}} <-
           command(state, "DOM.resolveNode", %{backendNodeId: backend_node_id}, session_id),
         {:ok, result} <-
           command(
             state,
             "Runtime.callFunctionOn",
             %{objectId: object_id, functionDeclaration: @read_value_js, returnByValue: true},
             session_id
           ) do
      {:ok, runtime_value(result)}
    end
  end

  defp url_value(state, tab) do
    case evaluate(tab, "location.href", state) do
      {:ok, result} -> {:ok, runtime_value(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp receipt(map, _key, {:ok, nil}), do: map
  defp receipt(map, key, {:ok, value}), do: Map.put(map, key, value)

  defp receipt(map, key, {:error, reason}) do
    Logger.warning("browser act receipt read failed for #{key}: #{inspect(reason)}")
    map
  end

  @submit_js """
  function() {
    const form = this.form || this.closest('form') || document.forms[0];
    if (!form) { return null; }
    const sels = ['button[type="submit"]', 'input[type="submit"]', "[role='search'] button", 'button:not([type])', 'button'];
    for (const sel of sels) {
      const btn = form.querySelector(sel);
      if (btn) { btn.click(); return ((btn.innerText || btn.value || sel) + '').trim().slice(0, 80); }
    }
    if (form.requestSubmit) { form.requestSubmit(); } else { form.submit(); }
    return 'form.submit()';
  }
  """

  defp click_primary_submit(state, session_id, backend_node_id) do
    with {:ok, %{"object" => %{"objectId" => object_id}}} <-
           command(state, "DOM.resolveNode", %{backendNodeId: backend_node_id}, session_id),
         {:ok, result} <-
           command(
             state,
             "Runtime.callFunctionOn",
             %{objectId: object_id, functionDeclaration: @submit_js, returnByValue: true},
             session_id
           ) do
      case runtime_value(result) do
        nil -> {:error, Error.new("no_submit_control", "No form or submit control found for ref")}
        label -> {:ok, label}
      end
    end
  end

  # The deterministic route onto a canvas-like surface: read the element's
  # viewport box, then click positions inside it with `click_coords` — the two
  # share the same CSS-viewport coordinate space, so no pixel guessing and no
  # dependency on where the window sits on the desktop.
  defp handle_get(%{"field" => "rect", "selector" => selector} = args, state)
       when is_binary(selector) do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, result} <- evaluate(tab, rect_expression(selector), state) do
      case runtime_value(result) do
        nil ->
          {:error, Error.new("not_found", "No element matches selector: #{selector}")}

        rect ->
          {:ok, %{"ok" => true, "target" => tab.id, "value" => rect}, state}
      end
    end
  end

  defp handle_get(args, state) do
    expression = get_expression(Map.get(args, "field", "text"))

    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, result} <- evaluate(tab, expression, state) do
      {:ok,
       %{"ok" => true, "target" => tab.id, "value" => capped_value(runtime_value(result), state)},
       state}
    end
  end

  # `text`/`html` on a heavy page can be megabytes; a get result rides straight
  # into model context, so it is capped like snapshots are (UTF-8 safe).
  defp capped_value(value, state) when is_binary(value) do
    max = state.config.snapshot_max_chars

    case String.split_at(value, max) do
      {head, ""} -> head
      {head, _rest} -> head <> "\n[truncated at #{max} characters]"
    end
  end

  defp capped_value(value, _state), do: value

  defp rect_expression(selector) do
    "(() => { const el = document.querySelector(#{Jason.encode!(selector)}); " <>
      "if (!el) return null; const r = el.getBoundingClientRect(); " <>
      "return {x: Math.round(r.x), y: Math.round(r.y), " <>
      "width: Math.round(r.width), height: Math.round(r.height)}; })()"
  end

  defp wait_for(args, state) do
    config = state.config
    timeout = bounded(Map.get(args, "timeout_ms"), config.wait_default_ms, config.wait_max_ms)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(Map.get(args, "wait_until", "text"), args, state, deadline)
  end

  defp do_wait_for(wait_until, args, state, deadline) do
    with {:ok, matched?, state} <- wait_matched?(wait_until, args, state) do
      if matched?,
        do: {:ok, %{"ok" => true, "matched" => true, "wait_until" => wait_until}, state},
        else: continue_wait(wait_until, args, state, deadline)
    end
  end

  defp continue_wait(wait_until, args, state, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, Error.new("timeout", "wait timed out")}
    else
      Process.sleep(state.config.wait_poll_interval_ms)
      do_wait_for(wait_until, args, state, deadline)
    end
  end

  defp wait_matched?("text", %{"text" => text} = args, state) when is_binary(text) do
    with {:ok, result, state} <-
           handle_get(%{"field" => "text", "target" => args["target"]}, state) do
      {:ok, String.contains?(get_in(result, ["value"]) || "", text), state}
    end
  end

  defp wait_matched?("url", %{"text" => text} = args, state) when is_binary(text) do
    with {:ok, result, state} <-
           handle_get(%{"field" => "url", "target" => args["target"]}, state) do
      {:ok, String.contains?(get_in(result, ["value"]) || "", text), state}
    end
  end

  defp wait_matched?("element", %{"ref" => ref} = args, state) when is_binary(ref) do
    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, _ref_data} <- ref_data(tab, ref, state) do
      {:ok, true, state}
    end
  end

  defp wait_matched?("element", %{"selector" => selector} = args, state)
       when is_binary(selector) do
    script = "Boolean(document.querySelector(#{Jason.encode!(selector)}))"

    with {:ok, tab, state} <- resolve_tab(Map.get(args, "target"), state),
         {:ok, tab, state} <- attach(tab, state),
         {:ok, result} <- evaluate(tab, script, state) do
      {:ok, runtime_value(result) == true, state}
    end
  end

  defp wait_matched?("load", args, state) do
    with {:ok, result, state} <-
           handle_get(%{"field" => "ready_state", "target" => args["target"]}, state) do
      {:ok, get_in(result, ["value"]) == "complete", state}
    end
  end

  defp wait_matched?(wait_until, _args, _state) do
    {:error, Error.new("invalid_action", "Unsupported wait_until value: #{inspect(wait_until)}")}
  end

  defp do_wait_download(state, deadline) do
    case next_download(state) do
      {:ok, result, state} -> {:ok, result, state}
      :none -> receive_download_event(state, deadline)
    end
  end

  defp receive_download_event(state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, Error.new("timeout", "download timed out")}
    else
      receive do
        {:cdp_event, method, event} ->
          method
          |> record_event(event, state)
          |> do_wait_download(deadline)

        {_port, {:data, _data}} ->
          do_wait_download(state, deadline)

        {_port, {:exit_status, status}} ->
          _state = %{stop_runtime(state) | console: crash_entry(status, state)}
          {:error, Error.new("browser_closed", "Browser exited while waiting for a download")}
      after
        min(remaining, state.config.wait_poll_interval_ms) ->
          do_wait_download(state, deadline)
      end
    end
  end

  defp next_download(state) do
    state.downloads
    |> Map.values()
    |> Enum.filter(&completed_download?(&1, state.reported_downloads))
    |> Enum.sort_by(&Map.get(&1, "completed_at", 0), :desc)
    |> List.first()
    |> case do
      nil -> :none
      download -> {:ok, download_result(download), mark_download_reported(state, download)}
    end
  end

  defp completed_download?(download, reported) do
    download["state"] == "completed" and not MapSet.member?(reported, download["guid"])
  end

  defp mark_download_reported(state, download) do
    %{state | reported_downloads: MapSet.put(state.reported_downloads, download["guid"])}
  end

  defp download_result(download) do
    %{
      "ok" => true,
      "guid" => download["guid"],
      "path" => download["path"],
      "url" => download["url"],
      "suggested_filename" => download["suggested_filename"]
    }
  end

  defp refresh_targets(%{runtime: nil} = state), do: {:ok, state}

  defp refresh_targets(state) do
    with {:ok, %{"targetInfos" => infos}} <- command(state, "Target.getTargets", %{}) do
      targets = infos |> selectable_targets() |> Map.new(&target_entry/1)
      active = active_target(state.active_target, targets)
      order = reconcile_order(state.tab_order, targets)
      # A gone tab's refs can never be clicked again; keeping its map only grows
      # state for the life of the profile (closes, evictions, crashes all funnel
      # through this refresh, so pruning here covers every removal path).
      ref_maps = Map.take(state.ref_maps, Map.keys(targets))

      {:ok,
       %{state | targets: targets, active_target: active, tab_order: order, ref_maps: ref_maps}}
    end
  end

  # Track tab age (oldest first) so the cap evicts the oldest. Drop ids whose
  # tabs are gone, then append any newly-seen tabs at the tail (newest). Leftover
  # tabs from a reattached crashed session are seen on the first refresh, before
  # any new `open`, so they sort oldest and get reaped first.
  defp reconcile_order(order, targets) do
    kept = Enum.filter(order, &Map.has_key?(targets, &1))
    seen = MapSet.new(kept)
    fresh = targets |> Map.keys() |> Enum.sort() |> Enum.reject(&MapSet.member?(seen, &1))
    kept ++ fresh
  end

  defp selectable_targets(infos) do
    infos = Enum.filter(infos, &track_target?/1)
    concrete = Enum.reject(infos, &about_blank_target?/1)

    case concrete do
      [] -> infos
      targets -> targets
    end
  end

  defp active_target(current, targets) when is_binary(current) do
    if Map.has_key?(targets, current), do: current, else: first_target_id(targets)
  end

  defp active_target(_current, targets), do: first_target_id(targets)

  defp resolve_tab(nil, %{targets: targets, active_target: nil} = state)
       when map_size(targets) == 1 do
    resolve_tab(first_target_id(targets), state)
  end

  defp resolve_tab(nil, %{active_target: id} = state) when is_binary(id),
    do: resolve_tab(id, state)

  defp resolve_tab(nil, _state) do
    {:error, Error.new("target_required", "target is required when more than one tab exists")}
  end

  defp resolve_tab(id, state) when is_binary(id) do
    case Map.fetch(state.targets, id) do
      {:ok, tab} -> {:ok, tab, state}
      :error -> {:error, Error.new("target_not_found", "Browser target not found: #{id}")}
    end
  end

  defp attach(%{session_id: session_id} = tab, state) when is_binary(session_id) do
    {:ok, tab, state}
  end

  defp attach(tab, state) do
    params = %{targetId: tab.target_id, flatten: true}

    with {:ok, %{"sessionId" => session_id}} <- command(state, "Target.attachToTarget", params) do
      tab = Map.put(tab, :session_id, session_id)
      state = put_in(state.targets[tab.id], tab)
      enable_page(tab, state)
      {:ok, tab, state}
    end
  end

  defp enable_page(tab, state) do
    command(state, "Page.enable", %{}, tab.session_id)
    command(state, "Runtime.enable", %{}, tab.session_id)
    # DOM domain is required for DOM.resolveNode (used to clear/replace a field
    # value and to read post-action receipts off the targeted node).
    command(state, "DOM.enable", %{}, tab.session_id)
    :ok
  end

  defp command(state, method, params, session_id \\ nil, timeout_ms \\ nil) do
    state.conn_mod.command(
      state.runtime.connection,
      method,
      params,
      session_id,
      timeout_ms || state.config.action_timeout_ms,
      state.config.cdp_response_grace_ms
    )
  end

  defp configure_downloads(state) do
    dir = download_dir(state)
    params = %{behavior: "allowAndName", downloadPath: dir, eventsEnabled: true}

    with :ok <- File.mkdir_p(dir),
         {:ok, _} <- command(state, "Browser.setDownloadBehavior", params) do
      {:ok, state}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new("download_setup_failed", inspect(reason))}
    end
  end

  defp final_url_allowed(url, config) do
    case Policy.validate_url(url, config) do
      {:ok, _uri} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp track_target?(%{"type" => type, "url" => url}) when type in @page_types do
    # Drop browser-internal pages from the agent's tab set. `about:blank` is not
    # internal: it is Chrome's startup page and an explicitly allowed URL. Stray
    # blank popups are filtered in selectable_targets/1 when a concrete page also
    # exists.
    not String.starts_with?(
      url || "",
      ["chrome://", "chrome-extension://", "devtools://"]
    )
  end

  defp track_target?(_info), do: false

  defp about_blank_target?(%{"url" => url}), do: String.trim(url || "") == "about:blank"

  defp target_entry(info) do
    id = tab_id(info["targetId"])

    {id,
     %{
       id: id,
       target_id: info["targetId"],
       session_id: nil,
       url: info["url"] || "",
       title: info["title"] || "",
       type: info["type"] || "page"
     }}
  end

  defp tab_values(state) do
    state.targets
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(&tab_result/1)
  end

  defp tab_result(tab) do
    %{
      "id" => tab.id,
      "target" => tab.id,
      "url" => tab.url,
      "title" => tab.title,
      "type" => tab.type
    }
  end

  defp snapshot_result(tab, rendered) do
    %{
      "ok" => true,
      "target" => tab.id,
      "url" => tab.url,
      "title" => tab.title,
      # "loading"/"interactive" tells the model a thin snapshot is a page still
      # building, not a page with nothing on it — wait, don't conclude.
      "ready_state" => Map.get(tab, :ready_state),
      "snapshot" => rendered.text,
      "refs" => Enum.map(rendered.refs, &Map.drop(&1, [:backend_node_id])),
      "truncated" => rendered.truncated
    }
  end

  # Scroll first (a no-op when already visible): a ref below the fold clicked at
  # its box-model center dispatches into nothing and reports success — the box is
  # read only AFTER the element is actually on screen.
  defp ref_box(tab, ref, state) do
    with {:ok, ref_data} <- ref_data(tab, ref, state),
         {:ok, _} <-
           command(
             state,
             "DOM.scrollIntoViewIfNeeded",
             %{backendNodeId: ref_data.backend_node_id},
             tab.session_id
           ),
         {:ok, %{"model" => %{"content" => points}}} <-
           command(
             state,
             "DOM.getBoxModel",
             %{backendNodeId: ref_data.backend_node_id},
             tab.session_id
           ) do
      {:ok, center(points)}
    else
      {:error, error} -> {:error, no_box_hint(ref, error)}
    end
  end

  # CDP's "Could not compute box model" means the node has no rendered box —
  # on real pages almost always a visually-hidden styled input (custom radio/
  # checkbox, the lichess time-control pattern) whose visible, clickable thing
  # is its LABEL. Name that recovery; the raw CDP text sends the model into a
  # retry loop on the same unclickable ref (observed live, twice).
  defp no_box_hint(ref, %Error{message: message} = error) do
    if message =~ "box model" do
      Error.new(
        "no_rendered_box",
        "#{ref} has no rendered box — it is likely a visually-hidden styled input " <>
          "(custom radio/checkbox). Click its visible LABEL ref from the snapshot " <>
          "instead, or use kind=click_coords with CSS-viewport x,y (from `get " <>
          "field=rect` — NOT raw pixels off a screenshot, which are device pixels; " <>
          "divide those by the screenshot's device_pixel_ratio).",
        error.details
      )
    else
      error
    end
  end

  defp no_box_hint(_ref, error), do: error

  defp ref_data(tab, ref, state) do
    case get_in(state.ref_maps, [tab.id, ref]) do
      nil ->
        {:error,
         Error.new(
           "stale_ref",
           "Element ref is stale or unknown: #{ref}. Refs belong to the snapshot they " <>
             "came from, and the page has changed since. Take a fresh `snapshot` and use " <>
             "a ref from it."
         )}

      data ->
        {:ok, data}
    end
  end

  defp center([x1, y1, _x2, _y2, x3, y3 | _rest]), do: %{x: (x1 + x3) / 2, y: (y1 + y3) / 2}
  defp center(_points), do: %{x: 0, y: 0}

  defp mouse_click(state, session_id, x, y) do
    with {:ok, _} <- mouse_event(state, session_id, "mousePressed", x, y),
         {:ok, _} <- mouse_event(state, session_id, "mouseReleased", x, y) do
      :ok
    end
  end

  defp mouse_event(state, session_id, type, x, y) do
    command(
      state,
      "Input.dispatchMouseEvent",
      %{type: type, x: x, y: y, button: "left", clickCount: 1},
      session_id
    )
  end

  defp key_event(state, session_id, key) do
    params = key_params(key, "keyDown")

    with {:ok, _} <- command(state, "Input.dispatchKeyEvent", params, session_id) do
      command(state, "Input.dispatchKeyEvent", key_params(key, "keyUp"), session_id)
    end
  end

  defp key_params("Enter", type), do: control_key(type, "Enter", "Enter", 13)
  defp key_params("Escape", type), do: control_key(type, "Escape", "Escape", 27)
  defp key_params("Tab", type), do: control_key(type, "Tab", "Tab", 9)
  defp key_params("Backspace", type), do: control_key(type, "Backspace", "Backspace", 8)
  defp key_params("Delete", type), do: control_key(type, "Delete", "Delete", 46)
  defp key_params("ArrowLeft", type), do: control_key(type, "ArrowLeft", "ArrowLeft", 37)
  defp key_params("ArrowUp", type), do: control_key(type, "ArrowUp", "ArrowUp", 38)
  defp key_params("ArrowRight", type), do: control_key(type, "ArrowRight", "ArrowRight", 39)
  defp key_params("ArrowDown", type), do: control_key(type, "ArrowDown", "ArrowDown", 40)

  defp key_params(key, type) when is_binary(key) and byte_size(key) == 1 do
    codepoint = key |> String.to_charlist() |> hd()
    %{type: type, key: key, text: text_for_type(key, type), windowsVirtualKeyCode: codepoint}
  end

  defp key_params(key, type), do: %{type: type, key: key}

  defp control_key("keyUp", key, code, virtual_code) do
    %{
      type: "keyUp",
      key: key,
      code: code,
      windowsVirtualKeyCode: virtual_code,
      nativeVirtualKeyCode: virtual_code
    }
  end

  defp control_key(type, key, code, virtual_code) do
    %{
      type: type,
      key: key,
      code: code,
      windowsVirtualKeyCode: virtual_code,
      nativeVirtualKeyCode: virtual_code,
      text: control_text(key),
      unmodifiedText: control_text(key)
    }
  end

  defp control_text("Enter"), do: "\r"
  defp control_text("Tab"), do: "\t"
  defp control_text(_key), do: ""

  defp text_for_type(_key, "keyUp"), do: ""
  defp text_for_type(key, _type), do: key

  defp evaluate(tab, expression, state) do
    params = %{expression: expression, returnByValue: true}
    command(state, "Runtime.evaluate", params, tab.session_id)
  end

  defp runtime_value(%{"result" => %{"value" => value}}), do: value
  defp runtime_value(%{"result" => %{"description" => value}}), do: value
  defp runtime_value(other), do: other

  defp storage_expression("session", key, value), do: storage_js("sessionStorage", key, value)
  defp storage_expression(_store, key, value), do: storage_js("localStorage", key, value)

  defp storage_js(store, nil, nil), do: "JSON.stringify(Object.assign({}, #{store}))"
  defp storage_js(store, key, nil), do: "#{store}.getItem(#{Jason.encode!(key)})"

  defp storage_js(store, key, value) do
    "#{store}.setItem(#{Jason.encode!(key)}, #{Jason.encode!(value)}); true"
  end

  defp get_expression("url"), do: "location.href"
  defp get_expression("title"), do: "document.title"
  defp get_expression("html"), do: "document.documentElement.outerHTML"
  defp get_expression("text"), do: "document.body ? document.body.innerText : ''"
  defp get_expression("count"), do: "document.querySelectorAll('*').length"
  defp get_expression("ready_state"), do: "document.readyState"
  defp get_expression(_field), do: "document.body ? document.body.innerText : ''"

  defp confined_upload_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    workspace_root = ConfigStore.workspace_paths() |> Map.fetch!(:workspace) |> Path.expand()

    with :ok <- under_root(expanded, workspace_root),
         true <- File.regular?(expanded) do
      {:ok, expanded}
    else
      false -> {:error, Error.new("upload_not_found", "Upload file was not found")}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp confined_upload_path(_path), do: {:error, Error.new("missing_arg", "upload requires path")}

  defp under_root(path, root) do
    if path == root or String.starts_with?(path, root <> "/") do
      :ok
    else
      {:error, Error.new("upload_blocked", "Upload path is outside the Fermix workspace")}
    end
  end

  defp bounded(value, _default, max) when is_integer(value) and value > 0, do: min(value, max)
  defp bounded(_value, default, _max), do: default

  defp write_artifact(state, kind, extension, bytes) do
    dir = artifact_dir(state, kind)
    path = Path.join(dir, "#{System.unique_integer([:positive, :monotonic])}.#{extension}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, bytes) do
      {:ok, path}
    else
      {:error, reason} -> {:error, Error.new("artifact_write_failed", inspect(reason))}
    end
  end

  defp artifact_dir(state, kind) do
    Path.join([
      Map.fetch!(ConfigStore.workspace_paths(), :browser),
      "artifacts",
      state.owner_key,
      kind
    ])
  end

  defp download_dir(state) do
    Path.join([
      Map.fetch!(ConfigStore.workspace_paths(), :browser),
      "downloads",
      state.owner_key
    ])
  end

  defp status_map(state) do
    %{
      "ok" => true,
      "profile" => state.profile_name,
      "running" => running?(state),
      "headless" => runtime_field(state, :headless),
      "cdp_port" => runtime_field(state, :port),
      "reused" => runtime_field(state, :reused) == true,
      "tabs" => map_size(state.targets)
    }
  end

  defp runtime_field(%{runtime: nil}, _key), do: nil
  defp runtime_field(%{runtime: runtime}, key), do: Map.get(runtime, key)
  defp running?(%{runtime: nil}), do: false
  defp running?(_state), do: true

  defp stop_runtime(%{runtime: nil} = state), do: state

  defp stop_runtime(state) do
    close_connection(state.runtime, state.conn_mod)
    state.launcher.stop(state.runtime, state.config)
    %{state | runtime: nil, targets: %{}, active_target: nil, tab_order: [], ref_maps: %{}}
  end

  defp close_connection(%{connection: pid}, conn_mod) when is_pid(pid), do: conn_mod.close(pid)
  defp close_connection(_runtime, _conn_mod), do: :ok

  defp crash_entry(status, state) do
    entry = %{"type" => "browser_exit", "status" => status}
    Enum.take([entry | state.console], state.config.console_buffer_limit)
  end

  defp record_event("Runtime.consoleAPICalled", event, state) do
    entry = %{
      "type" => get_in(event, ["params", "type"]),
      "args" => get_in(event, ["params", "args"]) || []
    }

    %{state | console: Enum.take([entry | state.console], state.config.console_buffer_limit)}
  end

  defp record_event("Runtime.exceptionThrown", event, state) do
    details = get_in(event, ["params", "exceptionDetails"]) || %{}
    entry = %{"type" => "exception", "text" => Map.get(details, "text"), "details" => details}
    %{state | console: Enum.take([entry | state.console], state.config.console_buffer_limit)}
  end

  defp record_event("Page.javascriptDialogOpening", event, state) do
    dialog = Map.get(event, "params", %{})
    %{state | dialogs: Enum.take([dialog | state.dialogs], state.config.dialog_buffer_limit)}
  end

  defp record_event("Browser.downloadWillBegin", event, state) do
    params = Map.get(event, "params", %{})
    guid = Map.get(params, "guid")
    path = if is_binary(guid), do: Path.join(download_dir(state), guid), else: nil

    download = %{
      "guid" => guid,
      "url" => Map.get(params, "url"),
      "suggested_filename" => Map.get(params, "suggestedFilename"),
      "path" => path,
      "state" => "in_progress"
    }

    %{state | downloads: Map.put(state.downloads, guid, download)}
  end

  defp record_event("Browser.downloadProgress", event, state) do
    params = Map.get(event, "params", %{})
    guid = Map.get(params, "guid")

    download =
      Map.get(state.downloads, guid, %{
        "guid" => guid,
        "path" => Path.join(download_dir(state), guid)
      })

    download = merge_download_progress(download, params)
    %{state | downloads: Map.put(state.downloads, guid, download)}
  end

  defp record_event(_method, _event, state), do: state

  defp merge_download_progress(download, params) do
    download
    |> Map.put("state", Map.get(params, "state"))
    |> Map.put("received_bytes", Map.get(params, "receivedBytes"))
    |> Map.put("total_bytes", Map.get(params, "totalBytes"))
    |> maybe_completed_at(Map.get(params, "state"))
  end

  defp maybe_completed_at(download, "completed") do
    Map.put(download, "completed_at", System.monotonic_time(:millisecond))
  end

  defp maybe_completed_at(download, _state), do: download

  defp emit(context, event, state, data) do
    data =
      Map.merge(data, %{
        "event" => event,
        "profile" => state.profile_name,
        "owner" => state.owner_key
      })

    Trace.record(:agent_event, Map.get(context, :agent_name, "browser"), data)
  end

  defp first_target_id(targets), do: targets |> Map.keys() |> Enum.sort() |> List.first()

  defp tab_id(target_id) do
    digest = :crypto.hash(:sha256, target_id) |> Base.encode16(case: :lower)
    "tab_" <> binary_part(digest, 0, 8)
  end

  defp schedule_idle(%{idle_ref: ref} = state) do
    if is_reference(ref), do: Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :idle_timeout, state.config.idle_profile_ttl_ms)
    %{state | idle_ref: new_ref}
  end

  defp touch_idle(state) do
    state |> touch_registry() |> schedule_idle()
  end

  defp touch_registry(%{registry: nil} = state), do: state
  defp touch_registry(%{key: nil} = state), do: state

  defp touch_registry(%{registry: registry, key: key, now_fn: now} = state) do
    Registry.update_value(registry, key, fn _old -> now.() end)
    state
  end

  defp via(opts) do
    case {Keyword.get(opts, :registry), Keyword.get(opts, :key)} do
      {registry, key} when not is_nil(registry) and not is_nil(key) ->
        {:via, Registry, {registry, key, System.monotonic_time(:millisecond)}}

      _other ->
        nil
    end
  end
end
