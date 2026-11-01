defmodule FermixWebWeb.SetupLive.AlwaysOn do
  @moduledoc """
  The browser setup's Always On tab (Always On setup §8.1), and the device
  role's word on the rest of the page.

  The tab draws the engine's summary (`home.status.summary`) and nothing of
  its own: for the action the owner presses it collects what the action
  `needs` (a token, with the provider when the summary lists several; the
  recovery passphrase, typed twice and compared here where none is set yet,
  else once; a size and place from `home.provision.options`, the
  recommendation chosen), asks its `confirm` sentence, and sends one step,
  `Management.AlwaysOn.act/2` (`home.act`) in the page's own process with
  `actor: :setup_page`, then draws the summary it answers. A `changed`
  refusal is shown in its sentence and the summary is read again. It never
  sequences calls, follows a job, picks a server or words what the engine
  words; Learn more and Open the provider's console are links to the
  action's `url`, and Update is the sentence alone (this page installs
  nothing).

  **Reads** run in `start_async` when the tab opens and at each
  `:home_status_changed` from `Home.StatusWatch`, which the page subscribes
  to once connected; every read carries a generation, so one an act or a
  later read overtook is dropped. The page monitors the watch and
  subscribes again when it comes back, trying at most `@watch_tries` times a
  second apart. Every act runs in `start_async` too.

  **Secrets.** A token or a passphrase lives only in the submitted event
  and the one act it becomes (`AlwaysOn.Input`, whose inspection withholds
  both): never in an assign, and every field is drawn empty, its form
  replaced after each submit (`form_gen`). The one-time code of a server of
  the owner's own is held in `Code`, whose inspection withholds it, and
  copied from the page by the `CopyText` hook, never through an event.

  **Move now** on the computer that sets Always On up restarts the engine:
  the restart overlay goes up first, with the tab stamped into the url
  (`push_patch`), and the act runs once the overlay had `@overlay_ms` to
  draw; a refusal takes it down and shows its sentence. On success the page
  reconnects through the overlay's `RestartReconnect` and mounts in the
  device role on this tab.

  All of its state is the page's one `:always_on` assign. Seams, under
  `config :fermix_web, :always_on`: `home` (the options every read and act
  takes, `Management.Home.status/1`'s and `Management.AlwaysOn.act/2`'s),
  `status_watch` (the watch's name), `forwarding` (a 0-arity reader of how
  this engine reaches its server, `Home.Link.forwarding/2` of the role the
  page booted in) and `overlay_ms`.
  """

  use FermixWebWeb, :html

  alias FermixCore.Clock
  alias FermixCore.Home.Link
  alias FermixCore.Home.Provision, as: HomeProvision
  alias FermixCore.Home.Provision.Registry
  alias FermixCore.Home.Role
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Management.AlwaysOn, as: ManagementAlwaysOn
  alias FermixCore.Management.AlwaysOn.Input
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Provision
  alias FermixCore.Setup.ConfigStore

  require Logger
  require Phoenix.LiveView

  defmodule Code do
    @moduledoc """
    The one-time code of a server of the owner's own, answered once by
    `own_server`, with the command to run there and until when the code
    works. LiveView's crash report prints every assign, so no print of it
    spells the code.
    """
    @enforce_keys [:code, :command, :until]
    defstruct [:code, :command, :until]

    @type t :: %__MODULE__{code: String.t(), command: String.t(), until: String.t()}

    defimpl Inspect do
      def inspect(_code, _opts), do: "#AlwaysOnCode<withheld>"
    end
  end

  # The restart overlay's head start before Move now's act.
  @overlay_ms 600
  # A watch that went away is looked for again this often, this many times.
  @watch_retry_ms 1_000
  @watch_tries 30
  @moves ~w(move_now try_again)

  @mismatch_sentence "The two passphrases do not match, so type the same one twice."
  @stopped_sentence "This step stopped before Fermix answered, so look at Always On again. " <>
                      "The daemon log says why."
  @unread_sentence "Always On could not be read here. The daemon log says why."

  # Each tab of the page by the management request its controls make, so the
  # one placement table (`Management.Placement`) decides which engine serves
  # it. A tab missing here fails loud rather than being served by default.
  @tab_requests %{
    "provider" => {"settings.apply", "providers.openai"},
    "realtime" => {"settings.apply", "realtime"},
    "channels" => {"settings.apply", "channels.telegram"},
    "transcription" => {"settings.apply", "transcription"},
    "plugins" => {"plugins.list", nil},
    "search" => {"settings.apply", "web_search"},
    "media" => {"settings.apply", "generate_image"},
    "sandbox" => {"settings.apply", "sandbox"},
    "coding" => {"settings.apply", "harness"},
    "memory" => {"settings.apply", "memory"},
    "personalization" => {"settings.apply", "personalization"},
    "cues" => {"settings.apply", "cues"},
    "always_on" => {"home.status", nil},
    "doctor" => {"doctor.start", nil}
  }

  # -- the device role's word on the page ----------------------------------------

  @doc """
  The tabs the primary serves, which a device-role page shows as unavailable
  rather than editable: none off the device role.
  """
  @spec primary_tabs(Role.record(), [%{id: String.t()}]) :: [String.t()]
  def primary_tabs(%{role: :device}, tabs) when is_list(tabs) do
    for %{id: id} <- tabs, place(Map.fetch!(@tab_requests, id)) == :primary, do: id
  end

  def primary_tabs(%{role: role}, tabs) when role in [:primary, :candidate] and is_list(tabs),
    do: []

  defp place({method, nil}), do: Placement.place(method, %{})
  defp place({method, section}), do: Placement.place(method, %{"section" => section})

  # An owner may have no Fermix app (a Homebrew or Linux install), so neither
  # names one; the server's own setup page is out of reach on most servers.
  @doc "The notice a device-role page leads with, or nil off the device role."
  @spec device_notice(Role.record()) :: String.t() | nil
  def device_notice(%{role: :device} = record) do
    "Fermix-wide settings live on #{server_words(record)}. This page sets up this computer " <>
      "and Always On."
  end

  def device_notice(%{role: role}) when role in [:primary, :candidate], do: nil

  @doc "The sentence a tab the primary serves shows in the device role."
  @spec unavailable_sentence(Role.record()) :: String.t()
  def unavailable_sentence(%{role: :device} = record),
    do: "These settings are Fermix-wide, so they live on #{server_words(record)}."

  defp server_words(%{primary: name}) when is_binary(name) and name != "",
    do: "your server, #{name}"

  defp server_words(_record), do: "your server"

  # -- state ---------------------------------------------------------------------

  @doc "The tab's state before anything is read, for the role the page booted in."
  @spec initial(Role.record()) :: map()
  def initial(%{role: role} = record) when role in [:primary, :device, :candidate] do
    %{
      record: record,
      forwarding: forwarding(record),
      summary: nil,
      gen: 0,
      form_gen: 0,
      open: nil,
      options: nil,
      code: nil,
      acting: nil,
      restarting?: false,
      error: nil,
      watch: nil,
      watch_tries: 0
    }
  end

  @doc "Whether the page shows the restart overlay for its own Move now."
  @spec restarting?(map()) :: boolean()
  def restarting?(%{restarting?: restarting?}), do: restarting?

  @doc "The page moved to `tab`: the Always On tab is read afresh."
  @spec on_tab(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def on_tab(socket, "always_on"), do: load(socket)
  def on_tab(socket, tab) when is_binary(tab), do: socket

  @doc "Reads the summary afresh, in a task; an older read still running is dropped."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    state = socket.assigns.always_on
    gen = state.gen + 1
    opts = engine_opts(state)

    socket
    |> put(gen: gen)
    |> Phoenix.LiveView.start_async({:always_on, :read}, fn -> {gen, Home.status(opts)} end)
  end

  # -- the watch -----------------------------------------------------------------

  @doc "On a connected page, listens to the Always On watch."
  @spec watch(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def watch(socket) do
    if Phoenix.LiveView.connected?(socket), do: subscribe(socket), else: socket
  end

  defp subscribe(socket) do
    case GenServer.whereis(watch_name()) do
      pid when is_pid(pid) ->
        ref = :erlang.monitor(:process, pid, tag: :always_on_watch)
        :ok = StatusWatch.subscribe(pid, self())
        put(socket, watch: ref, watch_tries: 0)

      nil ->
        retry_watch(socket)
    end
  end

  defp retry_watch(%{assigns: %{always_on: %{watch_tries: tries}}} = socket)
       when tries < @watch_tries do
    Process.send_after(self(), {:always_on_watch, :retry}, @watch_retry_ms)
    put(socket, watch: nil, watch_tries: tries + 1)
  end

  defp retry_watch(socket) do
    Logger.warning(
      "setup always on: the Always On watch is not running, so the tab reads Always On only " <>
        "when it opens"
    )

    put(socket, watch: nil)
  end

  @doc """
  A word about the watch: it went away (looked for again), or the time to
  look for it again came (ignored once the page listens again).
  """
  @spec handle_info(tuple(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_info({:always_on_watch, ref, :process, _pid, _reason}, socket) do
    if ref == socket.assigns.always_on.watch, do: retry_watch(socket), else: socket
  end

  def handle_info({:always_on_watch, :retry}, socket) do
    if socket.assigns.always_on.watch, do: socket, else: subscribe(socket)
  end

  # -- events --------------------------------------------------------------------

  @doc """
  One `always_on_*` event: a press of an action the summary drew, the step's
  form submitted, Back (closes the step) and Done (puts the code away).
  Nothing here raises: a failure is the tab's error line.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_event("always_on_press", %{"id" => id, "key" => key}, socket)
      when is_binary(id) and is_binary(key),
      do: press(socket, id, key)

  def handle_event("always_on_submit", params, socket) when is_map(params),
    do: submit(socket, Map.get(params, "always_on_step", %{}))

  def handle_event("always_on_back", _params, socket), do: close(socket)
  def handle_event("always_on_done", _params, socket), do: put(socket, code: nil)

  # Anything else is not an event this tab draws: it changes nothing, and only
  # its name reaches the log, never its parameters.
  def handle_event(event, _params, socket), do: ignored(socket, event)

  defp ignored(socket, event) do
    Logger.warning("setup always on: ignored a malformed #{event} event")
    socket
  end

  # The action pressed, as the screen it was drawn on offers it; a press from
  # a screen the page no longer draws reads the summary again, and one while
  # a step runs (its buttons are disabled) does nothing.
  defp press(%{assigns: %{always_on: %{acting: acting}}} = socket, _id, _key)
       when is_binary(acting),
       do: socket

  defp press(%{assigns: %{always_on: %{summary: %{} = summary}}} = socket, id, key) do
    case HomeSummary.find_action(summary, id, key) do
      {:ok, action} -> pressed(socket, action)
      :error -> load(socket)
    end
  end

  defp press(socket, _id, _key), do: ignored(socket, "always_on_press")

  # A link (Learn more, Open the console) and Update are never pressed here.
  defp pressed(socket, %{"url" => url}) when is_binary(url),
    do: ignored(socket, "always_on_press")

  defp pressed(socket, %{"id" => "update"}), do: ignored(socket, "always_on_press")

  defp pressed(socket, %{"needs" => [], "confirm" => nil} = action),
    do: act(socket, action, %Input{})

  defp pressed(socket, action) do
    socket
    |> put(open: action, options: nil, error: nil)
    |> next_form()
    |> choice_options(action)
  end

  defp close(socket), do: socket |> put(open: nil, options: nil, error: nil) |> next_form()

  defp next_form(socket), do: put(socket, form_gen: socket.assigns.always_on.form_gen + 1)

  # -- what an action needs ------------------------------------------------------

  defp submit(%{assigns: %{always_on: %{open: %{} = open, acting: nil}}} = socket, fields)
       when is_map(fields) do
    with {:ok, given} <- collected(open["needs"], fields, socket.assigns.always_on),
         {:ok, input} <- Input.decode(given) do
      act(socket, open, input)
    else
      {:error, {:invalid_params, _field, sentence}} -> refused_here(socket, sentence)
      {:error, sentence} when is_binary(sentence) -> refused_here(socket, sentence)
    end
  end

  defp submit(socket, _fields), do: ignored(socket, "always_on_submit")

  # The step stays open, its fields drawn empty again, with the sentence.
  defp refused_here(socket, sentence), do: socket |> put(error: sentence) |> next_form()

  defp collected(needs, fields, state) do
    Enum.reduce_while(needs, {:ok, %{}}, fn need, {:ok, given} ->
      case needed(need, fields, state) do
        {:ok, more} -> {:cont, {:ok, Map.merge(given, more)}}
        {:error, _sentence} = refused -> {:halt, refused}
      end
    end)
  end

  defp needed("token", fields, state) do
    case providers(state) do
      [_one] -> {:ok, %{"token" => fields["token"]}}
      _several -> {:ok, %{"token" => fields["token"], "provider" => fields["provider"]}}
    end
  end

  defp needed("new_recovery_passphrase", fields, _state) do
    if fields["passphrase"] == fields["passphrase_again"],
      do: {:ok, %{"recovery_passphrase" => fields["passphrase"]}},
      else: {:error, @mismatch_sentence}
  end

  defp needed("recovery_passphrase", fields, _state),
    do: {:ok, %{"recovery_passphrase" => fields["passphrase"]}}

  # The radio's value is `location/type`; anything else goes to the engine
  # as the size, which refuses it in its own words.
  defp needed("choice", fields, _state) do
    case fields["choice"] do
      choice when is_binary(choice) -> {:ok, chosen(String.split(choice, "/", parts: 2))}
      other -> {:ok, %{"type" => other}}
    end
  end

  defp chosen([location, type]), do: %{"type" => type, "location" => location}
  defp chosen([other]), do: %{"type" => other}

  @doc "The token screens the summary drew, one per provider."
  @spec providers(map()) :: [map()]
  def providers(%{summary: %{"detail" => %{"providers" => providers}}}) when is_list(providers),
    do: providers

  def providers(_state), do: []

  # `home.provision.options` of the provider Always On speaks of, read
  # while the choice is open.
  defp choice_options(socket, %{"needs" => needs}) do
    if "choice" in needs, do: read_options(socket), else: socket
  end

  defp read_options(socket) do
    state = socket.assigns.always_on
    opts = engine_opts(state)
    form_gen = state.form_gen

    socket
    |> put(options: :reading)
    |> Phoenix.LiveView.start_async({:always_on, :options}, fn ->
      {form_gen, Provision.options(%{"provider" => current_provider(opts)}, opts)}
    end)
  end

  defp current_provider(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
    HomeProvision.current(home, Keyword.get_lazy(opts, :providers, &Registry.all/0)).id()
  end

  # -- the step ------------------------------------------------------------------

  defp act(socket, action, input) do
    state = socket.assigns.always_on
    request = %{action: action["id"], key: action["key"], input: input}
    opts = Keyword.put(engine_opts(state), :actor, :setup_page)
    restarts? = restarts_here?(action, state)
    lead = if restarts?, do: overlay_ms(), else: 0

    socket
    |> put(acting: action["id"], error: nil, code: nil, restarting?: restarts?)
    |> next_form()
    |> overlay(restarts?)
    |> Phoenix.LiveView.start_async({:always_on, :act}, fn ->
      Process.sleep(lead)
      ManagementAlwaysOn.act(request, opts)
    end)
  end

  # Only this engine's own move restarts it; a linked desktop's replace moves
  # its server.
  defp restarts_here?(%{"id" => id}, %{forwarding: []}), do: id in @moves
  defp restarts_here?(_action, _state), do: false

  # The reload after the restart lands on this tab.
  defp overlay(socket, true),
    do: Phoenix.LiveView.push_patch(socket, to: ~p"/setup?tab=always_on")

  defp overlay(socket, false), do: socket

  @doc "The answer of a read, an act or the choice's options."
  @spec handle_async(tuple(), {:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_async({:always_on, :read}, {:ok, {gen, {:ok, record}}}, socket) do
    if gen == socket.assigns.always_on.gen,
      do: put(socket, summary: record["summary"]),
      else: socket
  end

  def handle_async({:always_on, :act}, {:ok, answer}, socket), do: answered(socket, answer)

  def handle_async({:always_on, :options}, {:ok, {form_gen, answer}}, socket) do
    if form_gen == socket.assigns.always_on.form_gen,
      do: options(socket, answer),
      else: socket
  end

  def handle_async({:always_on, what}, {:exit, reason}, socket) do
    Logger.error("setup always on: the #{what} stopped: #{inspect(reason)}")
    stopped(socket, what)
  end

  defp answered(socket, {:ok, %{"summary" => summary, "result" => result}}) do
    put(socket,
      summary: summary,
      gen: socket.assigns.always_on.gen + 1,
      code: code(result),
      open: nil,
      options: nil,
      acting: nil
    )
  end

  defp answered(socket, {:error, :changed, details}) do
    socket
    |> put(error: sentence(:changed, details), open: nil, options: nil)
    |> settled()
    |> load()
  end

  # A wrong input keeps the step open to type again; anything else closes it.
  defp answered(socket, {:error, :invalid_params, details}),
    do: socket |> put(error: sentence(:invalid_params, details)) |> settled()

  defp answered(socket, {:error, code, details}) when is_atom(code) do
    socket
    |> put(error: sentence(code, details), open: nil, options: nil)
    |> settled()
  end

  defp settled(socket), do: put(socket, acting: nil, restarting?: false)

  defp stopped(socket, :read), do: put(socket, error: @unread_sentence)
  defp stopped(socket, :options), do: put(socket, options: nil, error: @unread_sentence)

  defp stopped(socket, :act),
    do: socket |> put(error: @stopped_sentence, open: nil, options: nil) |> settled() |> load()

  defp options(socket, {:ok, options}), do: put(socket, options: options)

  defp options(socket, {:error, {_code, _field, sentence}}) when is_binary(sentence),
    do: put(socket, options: nil, error: sentence)

  # Every refusal names its own sentence; the protocol's message for the code
  # stands where one does not.
  defp sentence(_code, %{"sentence" => sentence}) when is_binary(sentence), do: sentence
  defp sentence(code, _details), do: Map.fetch!(Protocol.error_messages(), code)

  defp code(%{"code" => code, "expires_at" => at, "command" => command})
       when is_binary(code) and is_binary(at) and is_binary(command) do
    {:ok, expires, _offset} = DateTime.from_iso8601(at)
    %Code{code: code, command: command, until: Clock.stated_instant(expires)}
  end

  defp code(_result), do: nil

  # -- seams ---------------------------------------------------------------------

  defp seams, do: Application.get_env(:fermix_web, :always_on, [])

  # Every read and act takes the same options: the seams, the role the page
  # booted in and this engine's way to its server.
  defp engine_opts(%{record: record, forwarding: forwarding}) do
    seams()
    |> Keyword.get(:home, [])
    |> Keyword.put_new(:engine_role, record)
    |> Keyword.merge(forwarding)
  end

  defp forwarding(record) do
    case Keyword.fetch(seams(), :forwarding) do
      {:ok, read} -> read.()
      :error -> Link.forwarding(record, ConfigStore.fermix_home())
    end
  end

  defp watch_name, do: Keyword.get(seams(), :status_watch, StatusWatch)
  defp overlay_ms, do: Keyword.get(seams(), :overlay_ms, @overlay_ms)

  defp put(socket, changes),
    do: Phoenix.Component.update(socket, :always_on, &Map.merge(&1, Map.new(changes)))
end
