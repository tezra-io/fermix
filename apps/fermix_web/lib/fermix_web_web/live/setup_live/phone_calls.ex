defmodule FermixWebWeb.SetupLive.PhoneCalls do
  @moduledoc """
  The browser setup's Phone calls tab (M94 §12), the step after Voice and
  independent of Talk to Fermix: the switch beside where phone calls stand,
  the call in progress with its Stop, the recovery view of an unresolved call
  with the owner's confirmation that it ended, then the settings and the
  OpenAI key the phone engine shares with the OpenAI provider. It lists no
  finished calls: each call's end is a line in the daemon log, and its report
  is in the chat that asked for it. The page's Restart asks `restart_hold/0`
  first, so it refuses while a call is in progress.

  It calls what the management methods call, in the page's own process, so
  each write is validated and refused exactly as the socket's is:
  `FermixCore.Management.Settings` for the `phone_calls` section (its rows,
  and its write, which applies the switch once it lands),
  `FermixCore.Management.Secrets` for the two credentials, and
  `FermixCore.Management.PhoneCalls` for the status, the stop, the recovery
  view and its confirmation. Every label, sentence and state word is the daemon's; a
  refusal is said in the daemon's words.

  The switch is its own setter, never part of the settings form, as the
  StackChan switch is. The form has no button of its own: the step's footer
  below the page submits it (`form_id/0`). A blank secret field keeps the
  stored value.

  While a call is in progress the section reads its state again on a timer
  (`handle_info/2`), the Phone card's way, and stops once no call is.

  Seams, under `config :fermix_web, :phone_calls`: `management` (options for
  `Management.PhoneCalls`, which the section's rows and the secret writes are
  handed too), `settings` (options for the section's write, such as
  `:phone_calls_switch`) and `schedule` (a `(message, ms -> any)` that stands
  for the timer, for a test).
  """

  use FermixWebWeb, :html

  alias FermixCore.Management.PhoneCalls, as: ManagementPhoneCalls
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Secrets, as: ManagementSecrets
  alias FermixCore.Management.Settings, as: ManagementSettings

  @section "phone_calls"
  @switch "phone_calls_enabled"
  @form_id "phone-calls-form"
  # While a call holds the slot the section reads its state again this often,
  # as the Phone card reads a pairing (`SetupLive.Phone`); otherwise it waits.
  @poll_ms 2_000
  @live_states ~w(calling stopping)
  @fields ~w(voice caller_number sip_username)
  @secrets [{"sip_password", "phone_calls_sip_password"}, {"openai_api_key", "openai_api_key"}]

  @doc "The section's state before anything is read."
  @spec initial() :: map()
  def initial,
    do: %{
      rows: [],
      status: nil,
      recovery: [],
      unreadable: nil,
      notice: nil,
      refusal: nil,
      poll: nil
    }

  @doc "Reads the section's rows, the status and the recovery view."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    opts = management_opts()
    {:ok, %{"rows" => rows}} = ManagementSettings.get(@section, phone_calls: opts)

    socket
    |> update(fn state ->
      %{state | rows: rows, unreadable: nil}
      |> read(:status, ManagementPhoneCalls.status(opts), & &1)
      |> read(:recovery, ManagementPhoneCalls.recovery(opts), & &1["calls"])
    end)
    |> poll_while_live()
  end

  @doc """
  The section's own timed read (`{:phone_calls_poll, ref}`): read again while
  a call is in progress. A read an earlier poll scheduled is dropped.
  """
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_info({:phone_calls_poll, ref}, %{assigns: %{phone_calls: %{poll: ref}}} = socket),
    do: socket |> update(&%{&1 | poll: nil}) |> load()

  def handle_info({:phone_calls_poll, _stale}, socket), do: socket

  # One timer at a time, and only on a connected page while the summary says
  # a call is in progress.
  defp poll_while_live(%{assigns: %{phone_calls: %{poll: nil} = state}} = socket) do
    if Phoenix.LiveView.connected?(socket) and live?(state.status) do
      ref = make_ref()
      :ok = schedule({:phone_calls_poll, ref}, @poll_ms)
      update(socket, &%{&1 | poll: ref})
    else
      socket
    end
  end

  defp poll_while_live(socket), do: socket

  defp live?(%{"summary" => %{"state" => state}}), do: state in @live_states
  defp live?(_status), do: false

  defp schedule(message, wait_ms) do
    case Keyword.get(seams(), :schedule) do
      nil -> Process.send_after(self(), message, wait_ms)
      schedule when is_function(schedule, 2) -> schedule.(message, wait_ms)
    end

    :ok
  end

  # A read the daemon refused keeps the section drawn and says why, apart from
  # what the owner's last action answered.
  defp read(state, key, {:ok, view}, pick), do: Map.put(state, key, pick.(view))

  defp read(state, _key, {:error, {:unavailable, _capability, sentence}}, _pick),
    do: Map.put(state, :unreadable, sentence)

  @doc """
  One `phone_calls_*` event. Answers the socket and, for a settings write,
  its result, so the page refreshes its report; every other event answers nil.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {Phoenix.LiveView.Socket.t(), map() | nil}
  def handle_event("phone_calls_switch", %{"enabled" => value}, socket)
      when value in ["true", "false"],
      do: write(socket, %{@switch => value == "true"}, [])

  def handle_event("phone_calls_save", %{"phone_calls" => params}, socket) when is_map(params),
    do: write(socket, values(params), secrets(params))

  def handle_event("phone_calls_stop", %{"call_id" => call_id}, socket) when is_binary(call_id) do
    params = %{"call_id" => call_id}

    case ManagementPhoneCalls.route("phone_calls.stop", params, management_opts()) do
      {:ok, %{"sentence" => sentence}} -> {socket |> said(:notice, sentence) |> load(), nil}
      {:error, code, details} -> {socket |> said(:refusal, refusal(code, details)) |> load(), nil}
    end
  end

  # The owner's word, from the recovery view, that their Telnyx portal shows
  # the call ended (`phone_calls.recovery.confirm`).
  def handle_event("phone_calls_confirm", %{"call_id" => call_id}, socket)
      when is_binary(call_id) do
    params = %{"call_id" => call_id}

    case ManagementPhoneCalls.route("phone_calls.recovery.confirm", params, management_opts()) do
      {:ok, %{"sentence" => sentence}} -> {socket |> said(:notice, sentence) |> load(), nil}
      {:error, code, details} -> {socket |> said(:refusal, refusal(code, details)) |> load(), nil}
    end
  end

  @doc """
  Whether the page's Restart may run now: `:ok`, or the sentence that refuses
  it while a phone call is in progress (`Management.PhoneCalls.check_restart/1`).
  """
  @spec restart_hold() :: :ok | {:error, String.t()}
  def restart_hold do
    case ManagementPhoneCalls.check_restart(management_opts()) do
      :ok -> :ok
      {:error, :unavailable, %{"sentence" => sentence}} -> {:error, sentence}
    end
  end

  defp values(params) do
    for field <- @fields,
        is_binary(params[field]),
        into: %{},
        do: {"phone_calls_" <> field, params[field]}
  end

  # Only a field the owner typed into: a blank one keeps the stored value.
  defp secrets(params) do
    for {field, id} <- @secrets, String.trim(params[field] || "") != "", do: {id, params[field]}
  end

  # The settings first, then each secret, so a refused secret leaves the
  # settings saved and says which value was not stored.
  defp write(socket, values, secrets) do
    with {:ok, result} <- apply_values(values),
         :ok <- store_secrets(secrets) do
      {socket |> said(:notice, first_side_effect(result)) |> load(), result}
    else
      {:error, sentence} -> {socket |> said(:refusal, sentence) |> load(), nil}
    end
  end

  defp apply_values(values) when map_size(values) == 0, do: {:ok, %{"side_effects" => []}}

  defp apply_values(values) do
    opts = Keyword.put(settings_opts(), :phone_calls, management_opts())

    case ManagementSettings.apply(@section, values, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, write_sentence(reason)}
    end
  end

  defp store_secrets(secrets) do
    Enum.reduce_while(secrets, :ok, fn {id, value}, :ok ->
      case ManagementSecrets.set(id, value, phone_calls: management_opts()) do
        {:ok, _view} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, write_sentence(reason)}}
      end
    end)
  end

  defp write_sentence({:invalid_params, _field, sentence}), do: sentence
  defp write_sentence({:unavailable, _capability, sentence}), do: sentence
  defp write_sentence({:config_unreadable, sentence}), do: sentence
  defp write_sentence({:external_change, _sections}), do: message(:external_change)
  defp write_sentence({:secret_store_failed, _id, _reason}), do: message(:secret_store_failed)

  defp refusal(_code, %{"sentence" => sentence}) when is_binary(sentence), do: sentence
  defp refusal(code, _details), do: message(code)

  defp message(code), do: Map.fetch!(Protocol.error_messages(), code)

  defp first_side_effect(%{"side_effects" => [sentence | _rest]}), do: sentence
  defp first_side_effect(_result), do: nil

  defp said(socket, :notice, sentence),
    do: update(socket, &%{&1 | notice: sentence, refusal: nil})

  defp said(socket, :refusal, sentence),
    do: update(socket, &%{&1 | notice: nil, refusal: sentence})

  defp update(socket, fun), do: Phoenix.Component.update(socket, :phone_calls, fun)

  @doc """
  The options the page hands every setup save (`Setup.Wizard.save_answers/3`):
  where the hold on a credential a phone call in progress reads looks for
  the calls, the same seam the section's own reads use.
  """
  @spec wizard_opts() :: keyword()
  def wizard_opts, do: [phone_calls: management_opts()]

  defp management_opts, do: Keyword.get(seams(), :management, [])
  defp settings_opts, do: Keyword.get(seams(), :settings, [])
  defp seams, do: Application.get_env(:fermix_web, :phone_calls, [])

  # -- drawing -----------------------------------------------------------------------

  @doc "The id of the settings form, which the step's footer submits."
  @spec form_id() :: String.t()
  def form_id, do: @form_id

  attr :phone_calls, :map, required: true

  @doc """
  The tab's page, top to bottom: what phone calls are, where they stand
  beside their switch, what the owner's last action answered, a call in
  progress, each unresolved call, then the settings form.
  """
  def pane(%{phone_calls: %{rows: []}} = assigns), do: ~H""

  def pane(assigns) do
    state = assigns.phone_calls
    switch = row(state.rows, @switch)

    assigns =
      assign(assigns,
        switch: switch,
        on?: switch["value"] == true,
        status: state.status,
        summary: row(state.rows, "phone_calls_status")
      )

    ~H"""
    <div id="phone-calls" class="space-y-5">
      <div class="max-w-3xl">
        <h2 class="text-2xl font-semibold tracking-normal">{@switch["label"]}</h2>
        <p class="mt-2 text-sm leading-6 text-base-content/70">{@switch["footer"]}</p>
      </div>

      <div class="flex items-center justify-between gap-4 rounded-box border border-base-300 bg-base-200/40 px-4 py-3">
        <p id="phone-calls-summary" class="flex flex-wrap items-baseline gap-x-2 text-sm">
          <span class="font-medium">{@summary["value"]}</span>
          <span class="text-base-content/70">{@summary["footer"]}</span>
        </p>
        <form id="phone-calls-switch" phx-submit="phone_calls_switch">
          <input type="hidden" name="enabled" value={to_string(not @on?)} />
          <button type="submit" class={["btn btn-sm", @on? && "btn-primary"]}>
            {if @on?, do: "On", else: "Off"}
          </button>
        </form>
      </div>

      <p :if={@phone_calls.notice} id="phone-calls-notice" class="text-sm">
        {@phone_calls.notice}
      </p>
      <p :if={@phone_calls.refusal} id="phone-calls-refusal" class="text-sm text-warning">
        {@phone_calls.refusal}
      </p>
      <p
        :if={@phone_calls.unreadable}
        id="phone-calls-unreadable"
        class="text-sm text-base-content/70"
      >
        {@phone_calls.unreadable}
      </p>
      <.current_call :if={@status && @status["call"]} call={@status["call"]} />
      <.recovery :for={call <- @phone_calls.recovery} call={call} />
      <.settings_form rows={@phone_calls.rows} />
    </div>
    """
  end

  attr :rows, :list, required: true

  defp settings_form(assigns) do
    assigns =
      assign(assigns,
        voice: row(assigns.rows, "phone_calls_voice"),
        number: row(assigns.rows, "phone_calls_caller_number"),
        username: row(assigns.rows, "phone_calls_sip_username"),
        password: row(assigns.rows, "phone_calls_sip_password"),
        key: row(assigns.rows, "openai_api_key")
      )

    ~H"""
    <form
      id={form_id()}
      phx-submit="phone_calls_save"
      class="grid items-start gap-4 @xl:grid-cols-2"
    >
      <label class="form-control w-full">
        <span class="label pb-1 text-sm font-medium">{@voice["label"]}</span>
        <select name="phone_calls[voice]" class="select select-bordered w-full bg-base-100">
          <option
            :for={option <- @voice["options"]}
            value={option["value"]}
            selected={option["value"] == @voice["value"]}
          >
            {option["label"]}
          </option>
        </select>
        <span :if={@voice["footer"]} class="label pt-1 text-xs text-base-content/60">
          {@voice["footer"]}
        </span>
      </label>
      <.text_field row={@number} name="phone_calls[caller_number]" />
      <.text_field row={@username} name="phone_calls[sip_username]" />
      <.secret_field row={@password} name="phone_calls[sip_password]" />
      <.secret_field row={@key} name="phone_calls[openai_api_key]" />
    </form>
    """
  end

  attr :row, :map, required: true
  attr :name, :string, required: true

  defp text_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-sm font-medium">{@row["label"]}</span>
      <input
        type="text"
        name={@name}
        value={@row["value"]}
        placeholder={@row["example"]}
        class="input input-bordered w-full bg-base-100"
      />
      <span :if={@row["footer"]} class="label pt-1 text-xs text-base-content/60">
        {@row["footer"]}
      </span>
    </label>
    """
  end

  attr :row, :map, required: true
  attr :name, :string, required: true

  defp secret_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-sm font-medium">{@row["label"]}</span>
      <input
        type="password"
        name={@name}
        value=""
        placeholder={if @row["present"], do: "stored - leave blank to keep", else: "paste secret"}
        class="input input-bordered w-full bg-base-100 font-mono"
      />
      <span :if={@row["footer"]} class="label pt-1 text-xs text-base-content/60">
        {@row["footer"]}
      </span>
    </label>
    """
  end

  attr :call, :map, required: true

  defp current_call(assigns) do
    ~H"""
    <div id="phone-calls-call" class="rounded-box bg-base-200 p-4 text-sm space-y-2">
      <p class="font-medium">{@call["contact_name"]}</p>
      <p id="phone-calls-call-sentence">{@call["sentence"]}</p>
      <form
        :if={not @call["uncertain"] and @call["state"] != "stopping"}
        id="phone-calls-stop"
        phx-submit="phone_calls_stop"
      >
        <input type="hidden" name="call_id" value={@call["call_id"]} />
        <button type="submit" class="btn btn-sm btn-outline">Stop the call</button>
      </form>
    </div>
    """
  end

  attr :call, :map, required: true

  defp recovery(assigns) do
    ~H"""
    <div
      id={"phone-calls-recovery-#{@call["call_id"]}"}
      class="rounded-box border border-warning/40 p-4 text-sm space-y-2"
    >
      <p class="font-medium">{@call["sentence"]}</p>
      <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        <dt class="text-base-content/70">Attempted</dt>
        <dd>{at(@call["attempted_at"])}</dd>
        <dt class="text-base-content/70">Called</dt>
        <dd>{@call["contact_name"]} {@call["destination"]}</dd>
        <dt :if={@call["slot_release_at"]} class="text-base-content/70">Slot frees by</dt>
        <dd :if={@call["slot_release_at"]}>{at(@call["slot_release_at"])}</dd>
      </dl>
      <ul class="list-disc pl-5 space-y-1">
        <li :for={step <- @call["containment"]}>{step}</li>
      </ul>
      <form id={"phone-calls-confirm-#{@call["call_id"]}"} phx-submit="phone_calls_confirm">
        <input type="hidden" name="call_id" value={@call["call_id"]} />
        <button type="submit" class="btn btn-sm btn-outline">The call has ended</button>
      </form>
    </div>
    """
  end

  defp row(rows, key), do: Enum.find(rows, &(&1["key"] == key))

  # A time the daemon publishes, to the minute: how it reads, not what it says.
  defp at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
      {:error, _reason} -> iso
    end
  end

  defp at(nil), do: nil
end
