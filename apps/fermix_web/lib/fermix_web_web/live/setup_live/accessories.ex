defmodule FermixWebWeb.SetupLive.Accessories do
  @moduledoc """
  The browser setup's StackChan section (M91 E3; the Mac design's *Browser
  setup*, widened by the owner on 8 November so this page pairs too): an
  optional block under the Realtime tab's voice settings with the switch that
  allows a StackChan connection, the daemon's own sentence for where it
  stands and the voice the next call takes; and, on a local Mac primary with
  StackChan on, what the Mac app's Pet offers, drawn by
  `SetupLive.AccessoriesPane`: the USB devices and their actions, pairing
  with the code to compare, the paired robots with a test call, and the voice
  device. Checks, Calibrate head and the robot's own settings stay in Pet.

  It calls what the management methods call, in the page's own process:
  `FermixCore.Management.Accessories` for the status and every action
  (`route/3`, so each is validated and admitted exactly as the socket's
  `accessories.*` method is), and `FermixCore.Management.Settings` for the
  `accessories` section, whose write starts or stops the accessory link at
  once. The switch is its own setter, never part of the voice form's unsaved
  draft. Every success answers the daemon's whole status, which the section
  redraws from; a refusal is said in the daemon's words beside what it was
  about. Release, Forget and Revoke ask in place first.

  The page follows the picture by the accessory watcher's change notices
  (`Management.Accessories.watch/2`), one status read each. A watcher that
  ends while StackChan is on is looked for again every second, at most 30
  times. A pairing decision and a call's end name the attempt and the call
  the page's own status holds, never what the browser sends, and no link
  carries a credential.

  Seams, under `config :fermix_web, :accessories`: `management` (options for
  `Accessories`), `settings` (options for `Settings`) and `schedule` (how
  the watcher is looked for again, so a test delivers the tick itself).
  """

  use FermixWebWeb, :html

  alias FermixCore.Management.Accessories, as: ManagementAccessories
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Settings, as: ManagementSettings
  alias FermixWebWeb.SetupLive.AccessoriesPane

  require Logger

  @section "accessories"
  @switch "accessories_enabled"
  # The Mac app's Pet destination; the route parser takes no extra path.
  @pet_url "fermix://pet"
  @watch_retry_ms 1_000
  @watch_tries 30
  # The phases in which an attempt can still be decided or cancelled.
  @open_phases ~w(begun offered revealed committing)
  @port_methods %{
    "pair" => "accessories.pair.start",
    "retry" => "accessories.retry",
    "reconnect" => "accessories.reconnect"
  }
  @asks %{"release" => :release, "forget" => :forget, "revoke" => :revoke}

  @doc "The section's state before anything is read."
  @spec initial() :: map()
  def initial do
    %{
      status: nil,
      notice: nil,
      refusal: nil,
      asking: nil,
      name: nil,
      watch: nil,
      watch_tries: 0
    }
  end

  @doc "Reads the accessory status for the section."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    {:ok, status} = ManagementAccessories.status(management_opts())
    put(socket, :status, status)
  end

  @doc """
  On a connected page with StackChan on, listens to the accessory watcher,
  whose every change notice is one read of the status.
  """
  @spec watch(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def watch(socket) do
    if Phoenix.LiveView.connected?(socket) and is_nil(state(socket).watch) and on?(socket),
      do: subscribe(socket),
      else: socket
  end

  defp subscribe(socket) do
    case ManagementAccessories.watch(self(), management_opts()) do
      {:ok, watcher} ->
        ref = :erlang.monitor(:process, watcher, tag: :accessories_watch)
        update(socket, &%{&1 | watch: ref, watch_tries: 0})

      {:error, reason} ->
        Logger.info("setup accessories: the accessory watcher answered #{inspect(reason)}")
        retry_watch(socket)
    end
  end

  # Looked for again only while StackChan is on: one turned off has no
  # watcher to wait for, and its switch subscribes when it comes back on.
  defp retry_watch(socket) do
    tries = state(socket).watch_tries

    cond do
      not on?(socket) ->
        put(socket, :watch, nil)

      tries < @watch_tries ->
        schedule({:accessories_watch, :retry}, @watch_retry_ms)
        update(socket, &%{&1 | watch: nil, watch_tries: tries + 1})

      true ->
        Logger.warning(
          "setup accessories: no accessory watcher after #{@watch_tries} tries, so the " <>
            "StackChan section reads the status only when the page acts"
        )

        put(socket, :watch, nil)
    end
  end

  @doc """
  A word from the watcher: something changed (read the status again), the
  watcher ended (read it, and look for the watcher again), or the time to
  look came.
  """
  @spec handle_info(tuple(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_info({:accessories_changed, _version}, socket), do: load(socket)

  def handle_info({:accessories_watch, ref, :process, _pid, _reason}, socket) do
    if ref == state(socket).watch,
      do: socket |> put(:watch, nil) |> load() |> retry_watch(),
      else: socket
  end

  def handle_info({:accessories_watch, :retry}, socket) do
    if state(socket).watch, do: socket, else: socket |> load() |> watch()
  end

  @doc """
  One `accessories_*` event. Answers the socket and, for the switch, the
  settings write's result, so the page refreshes its report; every other
  event answers nil.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {Phoenix.LiveView.Socket.t(), map() | nil}
  def handle_event("accessories_switch", %{"enabled" => value}, socket)
      when value in ["true", "false"] do
    case ManagementSettings.apply(@section, %{@switch => value == "true"}, settings_opts()) do
      {:ok, result} -> {socket |> notice(side_effect(result)) |> load() |> watch(), result}
      {:error, refusal} -> {socket |> notice(refusal_sentence(refusal)) |> load(), nil}
    end
  end

  def handle_event("accessories_port", %{"action" => "release", "path" => path}, socket)
      when is_binary(path),
      do: {ask(socket, :release, path, path), nil}

  def handle_event("accessories_port", %{"action" => "pair_cancel", "path" => path}, socket)
      when is_binary(path),
      do: {cancel_pairing(socket, path), nil}

  def handle_event("accessories_port", %{"action" => action, "path" => path}, socket)
      when is_map_key(@port_methods, action) and is_binary(path),
      do: {act(socket, Map.fetch!(@port_methods, action), %{"path" => path}, path), nil}

  def handle_event("accessories_name", %{"name" => name}, socket) when is_binary(name),
    do: {put(socket, :name, name), nil}

  def handle_event("accessories_pair_begin", %{"path" => path, "name" => name}, socket)
      when is_binary(path) and is_binary(name) do
    params = named(%{"path" => path}, String.trim(name))
    {socket |> put(:name, name) |> act("accessories.pair.begin", params, path), nil}
  end

  def handle_event("accessories_decide", %{"matches" => matches}, socket)
      when matches in ["true", "false"],
      do: {decide(socket, matches == "true"), nil}

  def handle_event("accessories_robot", %{"action" => action} = params, socket),
    do: {robot_action(socket, action, params), nil}

  def handle_event("accessories_voice_device", %{"device" => device}, socket)
      when is_binary(device) do
    params = %{"device" => device}
    {act(socket, "accessories.voice_device.set", params, "voice_device"), nil}
  end

  def handle_event("accessories_confirm", _params, socket), do: {confirm(socket), nil}
  def handle_event("accessories_withdraw", _params, socket), do: {put(socket, :asking, nil), nil}

  # -- the actions -----------------------------------------------------------------

  # A paired robot's row: its call, its port's actions by the port it is
  # on, and Forget and Revoke, which ask first.
  defp robot_action(socket, "start_call", %{"id" => id}) when is_binary(id),
    do: act(socket, "accessories.call.start", %{"accessory_id" => id}, id)

  defp robot_action(socket, "end_call", %{"id" => id}) when is_binary(id),
    do: end_call(socket, id)

  defp robot_action(socket, "release", %{"id" => id, "path" => path})
       when is_binary(id) and is_binary(path),
       do: ask(socket, :release, path, id)

  defp robot_action(socket, action, %{"id" => id}) when action in ["forget", "revoke"],
    do: ask(socket, Map.fetch!(@asks, action), id, id)

  defp robot_action(socket, action, %{"id" => id, "path" => path})
       when is_map_key(@port_methods, action) and is_binary(id) and is_binary(path),
       do: act(socket, Map.fetch!(@port_methods, action), %{"path" => path}, id)

  # One `accessories.*` method through the management layer's own router, so
  # it is validated and admitted as the socket's is. `where` is what a
  # refusal is said beside: a port's path, a robot's id or the voice device.
  defp act(socket, method, params, where) do
    socket =
      case ManagementAccessories.route(method, params, management_opts()) do
        {:ok, status} -> socket |> put(:status, status) |> put(:refusal, nil)
        {:error, code, details} -> socket |> load() |> put(:refusal, {where, said(code, details)})
      end

    put(socket, :asking, nil)
  end

  # The daemon's own sentence, or the protocol's line for its code where the
  # refusal carries none (a malformed field).
  defp said(_code, %{"sentence" => sentence}) when is_binary(sentence), do: sentence
  defp said(code, _details), do: Map.fetch!(Protocol.error_messages(), code)

  # A blank name leaves the robot's name to the daemon, which keeps the kind's.
  defp named(params, ""), do: params
  defp named(params, name), do: Map.put(params, "name", name)

  # An open attempt on the port is cancelled by its id, so a newer one is not;
  # otherwise the port the owner chose is let go.
  defp cancel_pairing(socket, path) do
    params =
      case open_pairing(socket) do
        %{"path" => ^path, "attempt" => attempt} -> %{"path" => path, "attempt" => attempt}
        _other -> %{"path" => path}
      end

    act(socket, "accessories.pair.cancel", params, path)
  end

  # The owner's answer goes to the attempt the page shows. With none open in
  # its picture there is nothing to answer, and the page reads it again.
  defp decide(socket, matches?) do
    case open_pairing(socket) do
      %{"path" => path, "attempt" => attempt} ->
        params = %{"path" => path, "attempt" => attempt, "matches" => matches?}
        act(socket, "accessories.pair.decide", params, path)

      nil ->
        load(socket)
    end
  end

  defp open_pairing(socket) do
    case state(socket).status["pairing"] do
      %{"phase" => phase} = pairing when phase in @open_phases -> pairing
      _closed_or_none -> nil
    end
  end

  defp end_call(socket, id) do
    case state(socket).status["call"] do
      %{"accessory_id" => ^id, "call_id" => call_id} ->
        act(socket, "accessories.call.end", %{"accessory_id" => id, "call_id" => call_id}, id)

      _other_or_none ->
        load(socket)
    end
  end

  # Release, Forget and Revoke ask in place, by the robot's name where the
  # page knows it.
  defp ask(socket, kind, target, where) do
    asking = %{kind: kind, target: target, where: where, name: robot_name(socket, kind, target)}
    socket |> put(:asking, asking) |> put(:refusal, nil)
  end

  defp robot_name(socket, :release, path), do: name_where(socket, "path", path)
  defp robot_name(socket, _remove, id), do: name_where(socket, "accessory_id", id)

  defp name_where(socket, field, value) do
    Enum.find_value(state(socket).status["accessories"] || [], fn row ->
      if row[field] == value, do: row["name"]
    end)
  end

  defp confirm(socket) do
    case state(socket).asking do
      %{kind: :release, target: path, where: where} ->
        act(socket, "accessories.release", %{"path" => path}, where)

      %{kind: kind, target: id, where: where} ->
        act(socket, "accessories.#{kind}", %{"accessory_id" => id}, where)

      nil ->
        socket
    end
  end

  # -- the switch's answers ------------------------------------------------------------

  defp side_effect(%{"side_effects" => [sentence | _rest]}), do: sentence
  defp side_effect(_result), do: nil

  defp refusal_sentence({:invalid_params, _field, sentence}), do: sentence

  defp refusal_sentence({:external_change, _sections}),
    do: "The settings file changed outside Fermix."

  defp refusal_sentence({:config_unreadable, sentence}), do: sentence

  # The section exists only on a Mac, so the status says the same there.
  defp refusal_sentence({:unknown_section, _section}),
    do: ManagementAccessories.not_here_sentence(:not_mac)

  defp notice(socket, sentence), do: put(socket, :notice, sentence)

  # -- state and seams -------------------------------------------------------------

  defp state(socket), do: socket.assigns.accessories
  defp on?(socket), do: match?(%{"state" => "on"}, state(socket).status)

  defp put(socket, key, value), do: update(socket, &Map.put(&1, key, value))
  defp update(socket, fun), do: Phoenix.Component.update(socket, :accessories, fun)

  defp management_opts, do: Keyword.get(seams(), :management, [])
  defp settings_opts, do: Keyword.get(seams(), :settings, [])
  defp seams, do: Application.get_env(:fermix_web, :accessories, [])

  defp schedule(message, wait_ms) do
    case Keyword.get(seams(), :schedule) do
      nil -> Process.send_after(self(), message, wait_ms)
      schedule when is_function(schedule, 2) -> schedule.(message, wait_ms)
    end

    :ok
  end

  # -- drawing -----------------------------------------------------------------------

  attr :accessories, :map, required: true

  @doc "The section, below the voice form."
  def panel(%{accessories: %{status: nil}} = assigns), do: ~H""

  def panel(assigns) do
    status = assigns.accessories.status

    assigns =
      assign(assigns,
        status: status,
        local?: status["state"] != "needs_local_primary",
        on?: status["enabled"],
        ready?: status["state"] == "on",
        # A robot left chosen when StackChan was turned off, or a choice that
        # cannot be read: the Mac's own voice does not work until the owner
        # chooses again, which the daemon's sentences say. With StackChan on,
        # the voice device's own row says it.
        mac_voice?: status["voice_device"]["device"] == "desktop",
        unreadable_sentence:
          if(status["voice_device"]["device"] == "unreadable" and status["state"] != "on",
            do: status["voice_device"]["sentence"]
          ),
        pet_url: @pet_url
      )

    ~H"""
    <section id="accessories" class="mt-10 rounded-box border border-base-300 p-5 space-y-4">
      <div class="flex items-center justify-between gap-4">
        <div>
          <h3 class="text-base font-semibold">
            StackChan <span class="badge badge-ghost badge-sm ml-1">Optional</span>
          </h3>
          <p class="text-sm text-base-content/70">
            Talk through your robot's microphone and speaker. Your voice model and call limits stay the same.
          </p>
        </div>
        <form :if={@local?} id="accessories-switch" phx-submit="accessories_switch">
          <input type="hidden" name="enabled" value={to_string(not @on?)} />
          <button type="submit" class={["btn btn-sm", @on? && "btn-primary"]}>
            {if @on?, do: "On", else: "Off"}
          </button>
        </form>
      </div>

      <p id="accessories-sentence" class="text-sm">{@status["sentence"]}</p>
      <p
        :if={@unreadable_sentence}
        id="accessories-voice-device-sentence"
        class="text-sm text-warning"
      >
        {@unreadable_sentence}
      </p>
      <p :if={@accessories.notice} id="accessories-notice" class="text-sm text-warning">
        {@accessories.notice}
      </p>

      <div :if={@local?} class="text-sm space-y-1">
        <p>
          <span class="text-base-content/70">Voice for the next call</span>
          <span id="accessories-voice" class="ml-2 font-medium">
            {@status["voice"]["engine_label"]} · {@status["voice"]["voice"]}
          </span>
        </p>
        <p :if={not @status["voice"]["ready"]} id="accessories-voice-sentence" class="text-warning">
          {@status["voice"]["sentence"]}
        </p>
      </div>

      <AccessoriesPane.manage
        :if={@ready?}
        accessories={@accessories}
        efuse_sentence={ManagementAccessories.efuse_sentence()}
      />

      <div :if={@local?} class="flex items-center gap-3">
        <a
          :if={@ready?}
          id="accessories-setup-link"
          href={@pet_url}
          class="btn btn-sm btn-outline"
        >
          Set up in Fermix
        </a>
        <span :if={not @on? and @mac_voice?} class="text-sm text-base-content/70">
          StackChan is off by default. Your Mac voice still works.
        </span>
      </div>
    </section>
    """
  end
end
