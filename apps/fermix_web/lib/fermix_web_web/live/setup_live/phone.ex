defmodule FermixWebWeb.SetupLive.Phone do
  @moduledoc """
  The browser setup's Phone card (M51 web setup pairing): the panel on the
  Channels tab, and the dialog that pairs a phone the way the macOS and Linux
  apps do.

  It calls what the management methods call, in the page's own process:
  `FermixCore.Management.Mobile` for the channel, pairing and the paired phones,
  and `FermixCore.Management.Settings` for the `channels.mobile` rows, whose
  write starts or stops the channel at once. `PhonePairing` decides every step;
  this module makes the calls, schedules the reads and draws.

  All of its state is the page's one `:phone` assign. Every scheduled read
  carries the dialog's generation, so a read for a dialog that moved on or
  closed is dropped. The pairing link stays inside the Scan step's
  `PhonePairing.Link`, and its code is drawn at render, never held.

  Seams, under `config :fermix_web, :phone`: `mobile` (options for every
  `Mobile` call), `settings` (options for `Settings`), and `schedule` (how a
  later read is scheduled, so a test delivers the tick itself).
  """

  use FermixWebWeb, :html

  alias FermixCore.Management.Mobile
  alias FermixCore.Management.Settings, as: ManagementSettings
  alias FermixWebWeb.SetupLive.PhonePairing
  alias FermixWebWeb.SetupLive.PhonePairing.Link

  require Logger

  @section "channels.mobile"
  @switch "mobile_enabled"
  @poll_ms 1_000
  # Linux's bound: 150 s of reads outlasts the 120 s window, so a daemon that
  # never ends one cannot keep the dialog reading.
  @max_session_reads 150
  @reach_poll_ms 1_000
  @max_reach_reads 300
  @reach_backoff_ms 30_000
  @quiet_modules 4

  @type write :: map() | nil

  @doc "The Phone card's state before anything is read."
  @spec initial() :: map()
  def initial do
    %{
      dialog: :closed,
      gen: 0,
      reads: 0,
      polling?: false,
      status: nil,
      devices: nil,
      rows: nil,
      notice: nil,
      link_shown?: false,
      asking: nil,
      refusals: %{},
      advanced?: false,
      reach: %{reads: 0, wait_ms: @reach_poll_ms, scheduled?: false}
    }
  end

  @doc "Reads the channel, the paired phones and the switch rows, for the panel."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    update(socket, fn phone ->
      %{phone | status: read_status(), devices: read_devices(), rows: read_rows()}
    end)
  end

  @doc """
  One `phone_*` event. Answers the socket and, where it wrote settings, the
  write's result, so the page refreshes its report and its restart notice.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {Phoenix.LiveView.Socket.t(), write()}
  def handle_event("phone_open", %{"intent" => "pair"}, socket), do: {open_pair(socket), nil}
  def handle_event("phone_open", %{"intent" => "phones"}, socket), do: {open_phones(socket), nil}
  def handle_event("phone_close", _params, socket), do: {close(socket), nil}
  def handle_event("phone_turn_on", _params, socket), do: turn_on(socket)
  def handle_event("phone_start_over", _params, socket), do: {start_over(socket), nil}
  def handle_event("phone_show_link", _params, socket), do: {put(socket, :link_shown?, true), nil}
  def handle_event("phone_advanced", _params, socket), do: {toggle_advanced(socket), nil}
  def handle_event("phone_setting", params, socket), do: apply_setting(socket, params)

  def handle_event("phone_decide", %{"approved" => approved}, socket)
      when approved in ["true", "false"],
      do: {decide(socket, approved == "true"), nil}

  def handle_event("phone_forget_ask", %{"device" => id}, socket) when is_binary(id),
    do: {put(socket, :asking, id), nil}

  def handle_event("phone_forget_cancel", _params, socket), do: {put(socket, :asking, nil), nil}

  def handle_event("phone_forget", %{"device" => id}, socket) when is_binary(id),
    do: {forget(socket, id), nil}

  @doc "A scheduled read: a pairing window's, or the reach line's."
  @spec handle_info(tuple(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_info({:phone_poll, gen}, %{assigns: %{phone: %{gen: gen}}} = socket),
    do: poll(socket)

  def handle_info({:phone_poll, _stale}, socket), do: socket

  def handle_info(
        {:phone_reach, gen},
        %{assigns: %{phone: %{gen: gen, dialog: :phones}}} = socket
      ),
      do: follow_reach(socket)

  def handle_info({:phone_reach, _stale}, socket), do: socket

  @doc """
  The page is going away: a window it still shows is cancelled, so a closed tab
  never leaves one open for the rest of its two minutes.
  """
  @spec terminate(Phoenix.LiveView.Socket.t()) :: :ok
  def terminate(%{assigns: %{phone: phone}}), do: cancel(PhonePairing.open_session(phone.dialog))
  def terminate(_socket), do: :ok

  # -- opening and closing ---------------------------------------------------

  # A new dialog generation: whatever an older one scheduled is dropped.
  defp next_dialog(socket, step) do
    update(socket, fn phone ->
      %{
        phone
        | dialog: step,
          gen: phone.gen + 1,
          reads: 0,
          polling?: false,
          link_shown?: false,
          notice: nil,
          asking: nil,
          refusals: %{},
          reach: %{reads: 0, wait_ms: @reach_poll_ms, scheduled?: false}
      }
    end)
  end

  defp open_pair(socket) do
    socket |> next_dialog({:waiting, nil}) |> read_opening(nil)
  end

  defp open_phones(socket) do
    socket |> next_dialog(:phones) |> load() |> schedule_reach(@reach_poll_ms)
  end

  defp close(socket) do
    cancel(PhonePairing.open_session(socket.assigns.phone.dialog))
    socket |> next_dialog(:closed) |> load()
  end

  defp start_over(socket) do
    case socket.assigns.phone.dialog do
      {:ended, %{action: {:start_over, session}}} -> cancel(session)
      _other -> :ok
    end

    open_pair(socket)
  end

  # The channel as it stands decides the first step: a running one opens the
  # window, one that is not running is turned on first.
  defp read_opening(socket, side_effects) do
    case Mobile.status(mobile_opts()) do
      {:ok, status} ->
        socket
        |> put(:status, {:ok, status})
        |> advance({:status, status})
        |> refuse_turn_on(side_effects)
        |> start_if_waiting()

      {:error, refusal} ->
        advance(socket, {:refused, PhonePairing.refusal_sentence(refusal)})
    end
  end

  # A switch the channel did not follow keeps Turn on, in the daemon's words.
  defp refuse_turn_on(socket, side_effects) when side_effects in [nil, []], do: socket

  defp refuse_turn_on(socket, side_effects) do
    case socket.assigns.phone.dialog do
      {:turn_on, turn_on} ->
        put(socket, :dialog, {:turn_on, %{turn_on | refusal: Enum.join(side_effects, " ")}})

      _other ->
        socket
    end
  end

  defp start_if_waiting(socket) do
    if socket.assigns.phone.dialog == {:waiting, nil}, do: start_window(socket), else: socket
  end

  defp start_window(socket) do
    case Mobile.pair_start(mobile_opts()) do
      {:ok, view} -> advance(socket, {:started, view})
      {:error, {:busy, _operation}} -> busy(socket)
      {:error, refusal} -> advance(socket, {:refused, PhonePairing.refusal_sentence(refusal)})
    end
  end

  # A window is open somewhere else: the status names it, and a phone waiting
  # there for a decision is read at once so it can be compared here.
  defp busy(socket) do
    pairing =
      case Mobile.status(mobile_opts()) do
        {:ok, status} -> status["pairing"]
        {:error, _refusal} -> nil
      end

    socket = advance(socket, {:busy, pairing})

    if match?({:waiting, id} when is_binary(id), socket.assigns.phone.dialog),
      do: read_session(socket),
      else: socket
  end

  # -- the window ------------------------------------------------------------

  # One answer through the reducer. A window the answer leaves open that
  # nothing will show is cancelled, and a step that shows one is read again.
  defp advance(socket, answer) do
    {step, abandons} = PhonePairing.reduce(socket.assigns.phone.dialog, answer)
    cancel(abandons)

    socket
    |> put(:dialog, step)
    |> after_step(step)
    |> schedule_poll()
  end

  defp after_step(socket, {:paired, _name}), do: load(socket)
  defp after_step(socket, _step), do: socket

  defp poll(socket) do
    phone = socket.assigns.phone
    socket = update(socket, &%{&1 | polling?: false, reads: &1.reads + 1})

    if phone.reads + 1 > @max_session_reads, do: give_up(socket), else: read_session(socket)
  end

  defp read_session(socket) do
    case PhonePairing.open_session(socket.assigns.phone.dialog) do
      nil -> socket
      session -> answer_session(socket, Mobile.pair_get(session, mobile_opts()))
    end
  end

  defp answer_session(socket, {:ok, view}), do: advance(socket, {:session, view})

  defp answer_session(socket, {:error, refusal}),
    do: advance(socket, {:refused, PhonePairing.refusal_sentence(refusal)})

  # The read bound ran out with the window still open: it ends as one this page
  # cannot show, and the window is cancelled.
  defp give_up(socket) do
    cancel(PhonePairing.open_session(socket.assigns.phone.dialog))
    ending = %{sentence: PhonePairing.unreadable_sentence(), action: :pair_again}
    put(socket, :dialog, {:ended, ending})
  end

  defp decide(socket, approved?) do
    case socket.assigns.phone.dialog do
      {:compare, %{session: session}} ->
        answer_session(socket, Mobile.pair_decide(session, approved?, mobile_opts()))

      _other ->
        socket
    end
  end

  defp schedule_poll(socket) do
    phone = socket.assigns.phone

    if PhonePairing.open_session(phone.dialog) != nil and not phone.polling? do
      schedule({:phone_poll, phone.gen}, @poll_ms)
      put(socket, :polling?, true)
    else
      socket
    end
  end

  # Closing a window the daemon already ended answers that window as it is, so
  # only a call that could not be made is worth a line in the log.
  defp cancel(nil), do: :ok

  defp cancel(session) when is_binary(session) do
    case Mobile.pair_cancel(session, mobile_opts()) do
      {:ok, _view} ->
        :ok

      {:error, refusal} ->
        Logger.info("setup phone: cancelling a pairing window answered #{inspect(refusal)}")
    end
  end

  # -- turning on and the settings rows --------------------------------------

  defp turn_on(socket) do
    case ManagementSettings.apply(@section, %{@switch => true}, settings_opts()) do
      {:ok, result} ->
        {socket |> put(:rows, read_rows()) |> read_opening(result["side_effects"]), result}

      {:error, refusal} ->
        {refuse_turn_on(socket, [PhonePairing.refusal_sentence(refusal)]), nil}
    end
  end

  defp apply_setting(socket, %{"key" => key} = params) do
    with {:ok, row} <- find_row(socket, key),
         {:ok, value} <- row_value(row, params["value"]),
         {:ok, result} <- ManagementSettings.apply(@section, %{key => value}, settings_opts()) do
      notice = Enum.join(result["side_effects"] || [], " ")

      # A write can move the rail (Reach from anywhere turned on starts it), so
      # its line is followed again, as the apps do after every section write.
      socket =
        socket
        |> load()
        |> put(:notice, if(notice == "", do: nil, else: notice))
        |> schedule_reach(@reach_poll_ms)

      {socket, result}
    else
      {:error, refusal} ->
        {put(socket, :notice, PhonePairing.refusal_sentence(refusal)), nil}
    end
  end

  defp find_row(socket, key) do
    case socket.assigns.phone.rows do
      {:ok, rows} ->
        case Enum.find(rows, &(&1["key"] == key)) do
          nil ->
            {:error, {:invalid_params, key, "That setting is not part of the phone channel."}}

          row ->
            {:ok, row}
        end

      _unread ->
        {:error, {:unavailable, "settings"}}
    end
  end

  defp row_value(%{"kind" => "toggle"}, value) when value in ["true", "false"],
    do: {:ok, value == "true"}

  defp row_value(%{"kind" => "number", "key" => key}, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _other -> {:error, {:invalid_params, key, "Enter a whole number."}}
    end
  end

  defp row_value(%{"kind" => "text"}, value) when is_binary(value), do: {:ok, String.trim(value)}

  defp row_value(%{"key" => key}, _value),
    do: {:error, {:invalid_params, key, "That value cannot be saved."}}

  defp toggle_advanced(socket), do: update(socket, &%{&1 | advanced?: not &1.advanced?})

  # -- the phones --------------------------------------------------------------

  # Forget is asked in the phone's own row; only the second press forgets.
  defp forget(socket, id) do
    if socket.assigns.phone.asking == id do
      forgot(socket, id, Mobile.devices_revoke(id, mobile_opts()))
    else
      socket
    end
  end

  defp forgot(socket, id, {:ok, _revoked}) do
    socket |> load() |> update(&%{&1 | asking: nil, refusals: Map.delete(&1.refusals, id)})
  end

  defp forgot(socket, id, {:error, refusal}) do
    sentence = PhonePairing.refusal_sentence(refusal)
    update(socket, &%{&1 | asking: nil, refusals: Map.put(&1.refusals, id, sentence)})
  end

  # The reach line follows the rail while it can move by itself: every second
  # while the daemon answers, doubling to thirty while it refuses, at most 300
  # reads. A refused read keeps the line as last read.
  defp follow_reach(socket) do
    %{reach: reach} = socket.assigns.phone
    reads = reach.reads + 1

    {socket, wait_ms} =
      case Mobile.status(mobile_opts()) do
        {:ok, status} -> {put(socket, :status, {:ok, status}), @reach_poll_ms}
        {:error, _refusal} -> {socket, min(reach.wait_ms * 2, @reach_backoff_ms)}
      end

    socket
    |> put(:reach, %{reads: reads, wait_ms: wait_ms, scheduled?: false})
    |> schedule_reach(wait_ms)
  end

  defp schedule_reach(socket, wait_ms) do
    %{reach: reach, gen: gen} = phone = socket.assigns.phone

    if phone.dialog == :phones and reach_moves?(phone) and reach.reads < @max_reach_reads and
         not reach.scheduled? do
      schedule({:phone_reach, gen}, wait_ms)
      put(socket, :reach, %{reach | scheduled?: true})
    else
      socket
    end
  end

  defp reach_moves?(%{status: {:ok, status}}), do: PhonePairing.reach_moves?(status["remote"])
  defp reach_moves?(_phone), do: false

  # -- reads -----------------------------------------------------------------

  defp read_status do
    case Mobile.status(mobile_opts()) do
      {:ok, status} -> {:ok, status}
      {:error, refusal} -> {:error, PhonePairing.refusal_sentence(refusal)}
    end
  end

  defp read_devices do
    case Mobile.devices_list(mobile_opts()) do
      {:ok, devices} -> {:ok, devices}
      {:error, refusal} -> {:error, PhonePairing.refusal_sentence(refusal)}
    end
  end

  defp read_rows do
    case ManagementSettings.get(@section, settings_opts()) do
      {:ok, %{"rows" => rows}} -> {:ok, rows}
      {:error, refusal} -> {:error, PhonePairing.refusal_sentence(refusal)}
    end
  end

  # -- state and seams ---------------------------------------------------------

  defp put(socket, key, value), do: update(socket, &Map.put(&1, key, value))
  defp update(socket, fun), do: Phoenix.Component.update(socket, :phone, fun)

  defp seams, do: Application.get_env(:fermix_web, :phone, [])
  defp mobile_opts, do: Keyword.get(seams(), :mobile, [])
  defp settings_opts, do: Keyword.get(seams(), :settings, [])

  defp schedule(message, wait_ms) do
    case Keyword.get(seams(), :schedule) do
      nil -> Process.send_after(self(), message, wait_ms)
      schedule when is_function(schedule, 2) -> schedule.(message, wait_ms)
    end

    :ok
  end

  # -- drawing ---------------------------------------------------------------

  attr :phone, :map, required: true

  @doc "The Phone card's panel on the Channels tab: the switch, the status line and the button."
  def panel(assigns) do
    assigns =
      assign(assigns,
        row: PhonePairing.row(assigns.phone.status, assigns.phone.devices),
        switch: switch_row(assigns.phone.rows)
      )

    ~H"""
    <section id="phone-panel" class="space-y-4 rounded-box border border-base-300 bg-base-100 p-5">
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold">Phone</h3>
          <p id="phone-status" class="mt-0.5 text-sm text-base-content/70">{@row.status}</p>
        </div>
        <button
          type="button"
          class="btn btn-sm btn-primary shrink-0"
          phx-click="phone_open"
          phx-value-intent={if @row.opens == :phones, do: "phones", else: "pair"}
        >
          {if @row.opens == :phones, do: "Change…", else: "Pair a phone…"}
        </button>
      </div>
      <.setting_row :if={@switch} row={@switch} />
      <p :if={@phone.notice && @phone.dialog == :closed} class="text-xs text-warning">
        {@phone.notice}
      </p>
      <.dialog phone={@phone} />
    </section>
    """
  end

  attr :phone, :map, required: true

  defp dialog(%{phone: %{dialog: :closed}} = assigns), do: ~H""

  defp dialog(assigns) do
    ~H"""
    <div
      id="phone-dialog"
      class="fixed inset-0 z-50 grid place-items-center bg-base-300/70 p-4 backdrop-blur-sm"
      phx-window-keydown="phone_close"
      phx-key="Escape"
    >
      <div
        class="flex max-h-[90vh] w-full max-w-md flex-col rounded-box border border-base-300 bg-base-100 shadow-lg"
        role="dialog"
        aria-modal="true"
        aria-labelledby="phone-dialog-title"
      >
        <div class="flex items-center gap-3 border-b border-base-300 px-5 py-4">
          <h3 id="phone-dialog-title" class="flex-1 text-base font-semibold">Phone</h3>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-circle"
            phx-click="phone_close"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <div class="flex-1 space-y-4 overflow-y-auto px-5 py-5">
          <.step step={@phone.dialog} phone={@phone} />
        </div>
      </div>
    </div>
    """
  end

  attr :step, :any, required: true
  attr :phone, :map, required: true

  defp step(%{step: {:waiting, _session}} = assigns) do
    ~H"""
    <div class="grid place-items-center py-10">
      <span class="loading loading-spinner loading-md text-primary" aria-label="Waiting" />
    </div>
    """
  end

  defp step(%{step: {:turn_on, turn_on}} = assigns) do
    assigns = assign(assigns, turn_on: turn_on, lead: switch_footer(assigns.phone.rows))

    ~H"""
    <p :if={@lead} class="text-sm">{@lead}</p>
    <p :if={@turn_on.action == :restart} class="text-sm text-base-content/70">
      Fermix stops and starts again. Anything it is doing right now is interrupted.
      Once it is back, choose Pair a phone… again.
    </p>
    <p :if={@turn_on.refusal} class="text-sm text-error">{@turn_on.refusal}</p>
    <div class="flex justify-end gap-2">
      <button type="button" class="btn btn-sm" phx-click="phone_close">Cancel</button>
      <button
        :if={@turn_on.action == :switch_on}
        type="button"
        class="btn btn-sm btn-primary"
        phx-click="phone_turn_on"
      >
        Turn on
      </button>
      <button
        :if={@turn_on.action == :restart}
        type="button"
        class="btn btn-sm btn-primary"
        phx-click="apply_restart"
      >
        Restart Fermix
      </button>
    </div>
    """
  end

  defp step(%{step: {:scan, scan}} = assigns) do
    assigns = assign(assigns, scan: scan)

    ~H"""
    <p class="text-sm">On your Android phone, open Fermix and scan this code.</p>
    <div class="grid place-items-center">
      <div class="rounded-box bg-white p-3">
        <.code link={@scan.link} />
      </div>
    </div>
    <p class="text-center text-sm tabular-nums text-base-content/70" aria-live="polite">
      {PhonePairing.countdown(@scan.ttl_ms)}
    </p>
    <div :if={!@phone.link_shown?} class="text-center">
      <button type="button" class="link text-sm" phx-click="phone_show_link">
        Can't scan the code?
      </button>
    </div>
    <div :if={@phone.link_shown?} class="space-y-2">
      <p class="text-xs font-medium text-base-content/70">Pairing link</p>
      <code
        id="phone-pairing-link"
        class="line-clamp-3 block break-all rounded-field bg-base-200 p-2 font-mono text-xs"
      >
        {@scan.link.text}
      </code>
      <button
        id="phone-copy-link"
        type="button"
        class="btn btn-xs"
        phx-hook="CopyText"
        data-copy-from="phone-pairing-link"
      >
        Copy link
      </button>
    </div>
    <div class="flex justify-end">
      <button type="button" class="btn btn-sm" phx-click="phone_close">Cancel</button>
    </div>
    """
  end

  defp step(%{step: {:compare, compare}} = assigns) do
    assigns = assign(assigns, compare: compare)

    ~H"""
    <div>
      <p class="text-base font-semibold">{@compare.device_name} wants to pair</p>
      <p class="text-sm text-base-content/70">{@compare.model}</p>
    </div>
    <p
      class="text-center font-mono text-4xl font-semibold tracking-widest tabular-nums"
      aria-label={PhonePairing.spoken(@compare.digits, @compare.device_name)}
    >
      {PhonePairing.grouped(@compare.digits)}
    </p>
    <p class="text-sm">Approve only if the phone shows the same six digits.</p>
    <p class="text-sm text-base-content/70">{@compare.hardware}</p>
    <form phx-submit="phone_decide" class="flex justify-end gap-2">
      <button type="submit" name="approved" value="false" class="btn btn-sm">Deny</button>
      <button type="submit" name="approved" value="true" class="btn btn-sm">Approve</button>
    </form>
    """
  end

  defp step(%{step: {:paired, name}} = assigns) do
    assigns = assign(assigns, name: name)

    ~H"""
    <p class="text-sm">Paired with {@name}.</p>
    <div class="flex justify-end">
      <button
        type="button"
        class="btn btn-sm btn-primary"
        phx-click="phone_open"
        phx-value-intent="phones"
      >
        Done
      </button>
    </div>
    """
  end

  defp step(%{step: {:ended, ending}} = assigns) do
    assigns = assign(assigns, ending: ending)

    ~H"""
    <p class="text-sm">{@ending.sentence}</p>
    <div class="flex justify-end gap-2">
      <button type="button" class="btn btn-sm" phx-click="phone_close">Done</button>
      <button
        :if={@ending.action == :pair_again}
        type="button"
        class="btn btn-sm btn-primary"
        phx-click="phone_open"
        phx-value-intent="pair"
      >
        Pair again
      </button>
      <button
        :if={match?({:start_over, _session}, @ending.action)}
        type="button"
        class="btn btn-sm btn-primary"
        phx-click="phone_start_over"
      >
        Start over
      </button>
    </div>
    """
  end

  defp step(%{step: :phones} = assigns) do
    assigns =
      assign(assigns,
        devices: device_list(assigns.phone.devices),
        listing_refusal: listing_refusal(assigns.phone.devices),
        now: System.os_time(:second),
        reach: reach_row(assigns.phone.rows),
        reach_line: reach_line(assigns.phone.status),
        advanced: advanced_rows(assigns.phone.rows)
      )

    ~H"""
    <p :if={@listing_refusal} class="text-sm text-error">{@listing_refusal}</p>
    <ul :if={@devices != []} class="divide-y divide-base-300 rounded-field border border-base-300">
      <li :for={device <- @devices} class="space-y-2 px-3 py-2.5">
        <div class="flex items-center justify-between gap-3">
          <div class="min-w-0">
            <p class="truncate text-sm font-medium">{device["name"]}</p>
            <p class="truncate text-xs text-base-content/60">
              {PhonePairing.detail(device["model"] || "", device["last_seen"], @now)}
            </p>
          </div>
          <button
            :if={@phone.asking != device["device_id"]}
            type="button"
            class="btn btn-xs"
            phx-click="phone_forget_ask"
            phx-value-device={device["device_id"]}
          >
            Forget…
          </button>
          <div :if={@phone.asking == device["device_id"]} class="flex gap-1.5">
            <button type="button" class="btn btn-xs" phx-click="phone_forget_cancel">Cancel</button>
            <button
              type="button"
              class="btn btn-xs btn-error"
              phx-click="phone_forget"
              phx-value-device={device["device_id"]}
            >
              Forget this phone
            </button>
          </div>
        </div>
        <p :if={@phone.refusals[device["device_id"]]} class="text-xs text-error">
          {@phone.refusals[device["device_id"]]}
        </p>
      </li>
    </ul>
    <button type="button" class="btn btn-sm" phx-click="phone_open" phx-value-intent="pair">
      {if @devices == [], do: "Pair a phone…", else: "Pair another phone"}
    </button>
    <div :if={@reach} class="space-y-1">
      <.setting_row row={@reach} />
      <p
        :if={@reach_line}
        id="phone-reach-line"
        class={[
          "text-xs",
          if(elem(@reach_line, 1) == :failure, do: "text-warning", else: "text-base-content/60")
        ]}
      >
        {elem(@reach_line, 0)}
      </p>
    </div>
    <div :if={@advanced != []} class="space-y-3">
      <button
        type="button"
        class="link text-sm"
        phx-click="phone_advanced"
        aria-expanded={to_string(@phone.advanced?)}
      >
        Advanced
      </button>
      <div :if={@phone.advanced?} class="space-y-3">
        <.setting_row :for={row <- @advanced} row={row} />
      </div>
    </div>
    <p :if={@phone.notice} class="text-xs text-warning">{@phone.notice}</p>
    <div class="flex justify-end">
      <button type="button" class="btn btn-sm btn-primary" phx-click="phone_close">Done</button>
    </div>
    """
  end

  attr :row, :map, required: true

  # One `channels.mobile` row as the daemon describes it. A toggle writes at
  # once; a number or text row writes when its form is submitted.
  defp setting_row(%{row: %{"kind" => "toggle"}} = assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4">
      <div class="min-w-0">
        <p class="text-sm">{@row["label"]}</p>
        <p :if={@row["footer"]} class="text-xs text-base-content/60">{@row["footer"]}</p>
        <p :if={@row["info"]} class="mt-1 text-xs text-base-content/50">{@row["info"]}</p>
      </div>
      <input
        type="checkbox"
        class="toggle toggle-sm toggle-primary mt-0.5"
        checked={@row["value"] == true}
        aria-label={@row["label"]}
        phx-click="phone_setting"
        phx-value-key={@row["key"]}
        phx-value-value={to_string(@row["value"] != true)}
      />
    </div>
    """
  end

  defp setting_row(assigns) do
    ~H"""
    <form phx-submit="phone_setting" class="space-y-1">
      <input type="hidden" name="key" value={@row["key"]} />
      <label class="block text-sm" for={"phone-row-" <> @row["key"]}>{@row["label"]}</label>
      <div class="flex gap-2">
        <input
          id={"phone-row-" <> @row["key"]}
          type={if @row["kind"] == "number", do: "number", else: "text"}
          name="value"
          value={@row["value"]}
          min={@row["min"]}
          max={@row["max"]}
          class="input input-sm input-bordered w-full"
        />
        <button type="submit" class="btn btn-sm">Save</button>
      </div>
      <p :if={@row["footer"]} class="text-xs text-base-content/60">{@row["footer"]}</p>
      <p :if={@row["restart"]} class="text-xs text-base-content/50">Restart to apply.</p>
    </form>
    """
  end

  attr :link, Link, required: true

  # The pairing code, drawn from the link at render and never held: correction
  # level M, a four-module quiet zone, one path of whole modules.
  defp code(assigns) do
    assigns = assign(assigns, drawing: drawing(assigns.link))

    ~H"""
    <svg
      :if={@drawing}
      role="img"
      aria-label="Pairing code for your phone"
      viewBox={"0 0 #{@drawing.side} #{@drawing.side}"}
      width="240"
      height="240"
      shape-rendering="crispEdges"
    >
      <path d={@drawing.path} fill="#000" />
    </svg>
    """
  end

  defp drawing(%Link{text: text}) do
    case QRCode.create(text, :medium) do
      {:ok, %{matrix: matrix}} -> %{side: length(matrix) + 2 * @quiet_modules, path: path(matrix)}
      {:error, _reason} -> nil
    end
  end

  defp path(matrix) do
    for {row, y} <- Enum.with_index(matrix),
        {1, x} <- Enum.with_index(row),
        into: "",
        do: "M#{x + @quiet_modules} #{y + @quiet_modules}h1v1h-1z"
  end

  # -- rows and reads, for drawing -------------------------------------------

  defp switch_row({:ok, rows}), do: Enum.find(rows, &(&1["key"] == @switch))
  defp switch_row(_rows), do: nil

  defp switch_footer(rows), do: rows |> switch_row() |> then(&(&1 && &1["footer"]))

  defp reach_row({:ok, rows}), do: Enum.find(rows, &(&1["key"] == "mobile_iroh"))
  defp reach_row(_rows), do: nil

  defp advanced_rows({:ok, rows}), do: Enum.filter(rows, &(&1["advanced"] == true))
  defp advanced_rows(_rows), do: []

  defp reach_line({:ok, status}), do: PhonePairing.reach_line(status["remote"])
  defp reach_line(_status), do: nil

  defp device_list({:ok, %{"devices" => devices}}), do: devices
  defp device_list(_devices), do: []

  defp listing_refusal({:error, sentence}), do: sentence
  defp listing_refusal(_devices), do: nil
end
