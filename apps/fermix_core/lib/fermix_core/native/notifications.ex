defmodule FermixCore.Native.Notifications do
  @moduledoc """
  Notifications on this computer (M76 §4.3, §4.6): the service, the behaviour
  its backends implement, and the delivery adapter the reminder rail resolves
  for platform `"computer"`.

  `resolve/1` is the only place a backend is chosen, from two facts: the
  provider (`Native.Provider`), a fact of the build, and the placement
  (`placement/1`), where the home runs. Placed here, `Notifications.MacApp`
  where the provider is `:mac_app`, `Notifications.DBus` where it is
  `:dbus`; placed on the owner's computers (an Always On server's primary,
  M99 §10.1), `Notifications.Computers`, which asks each connected computer
  over its link to post the notification its own local way. A build whose
  provider is `:none` (a standalone engine or a source run on a Mac) has no
  backend and refuses with a sentence naming the build, as
  `PlaceSearch.Backend` names a build without the Apple Maps helper. Nothing
  substitutes another backend: no `osascript`, no `notify-send`, no poster of
  the engine's own, and a home is never tried in one place and then the
  other.

  A backend answers two questions, both asked live:

    * `ready/2`: could a notification be shown now? The readiness a reminder
      stored for this computer is accepted on, answered as one sentence a tool
      returns. `context` is the turn's tool context, for a backend that must
      know whether the person is at this computer (`Native.local_surface?/1`)
      before it may raise a permission prompt.
    * `post/2`: show one notification, answering the backend's id for it or a
      reason from the closed set `t:reason/0`.

  As the delivery adapter, `send_message/3` is the face `Delivery.ChannelSend`
  dispatches a reminder attempt to: one post, its reason reduced by
  `delivery_error/1` to `Delivery.Error`'s closed vocabulary, which decides
  whether the rail retries it on the same target. The body is the text
  `Temporal.Renderer.render/2` produced, passed whole, and the summary is the
  event's title, carried as the `:title` send option; nothing here renders.
  """

  require Logger

  alias FermixCore.Delivery.Error
  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Home.Role
  alias FermixCore.Home.ServerPrimary
  alias FermixCore.Native.Notifications.Computers
  alias FermixCore.Native.Notifications.DBus
  alias FermixCore.Native.Notifications.MacApp
  alias FermixCore.Native.Provider
  alias FermixCore.Setup.ConfigStore

  @typedoc """
  One notification: its summary, its body, whether it rings with sound, the
  reminder it is for, if any, and its key. A backend that offers an action on
  it (the Mac app's Snooze 10 minutes) names the reminder the press acts on;
  D-Bus offers none and ignores it. The key is the reminder's own
  (`proactive_key`, stable across its retries): the owner's computers show
  one key once, and a backend on this computer ignores it.
  """
  @type notification :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:sound) => boolean(),
          optional(:reminder_id) => String.t() | nil,
          optional(:key) => String.t() | nil
        }

  @typedoc "The backend's own id for a posted notification (the server's, on D-Bus)."
  @type id :: String.t()

  @typedoc """
  Why a post did not show, the closed set every backend answers in:

    * `:not_offered`: this build's provider serves no notifications;
    * `:backend_missing`: the backend's own tool is not on this machine
      (`busctl` not on `PATH`);
    * `:no_server`: Linux, no session bus, or nothing owns the notification
      server's name (a headless host, a `--system` unit, a logged-out laptop);
    * `:host_unavailable`: Mac, the Fermix app is not attached, did not attach
      by its launch deadline, or a launch is cooling down;
    * `:not_authorized`: Mac, the app holds no notification grant;
    * `:timeout`: the backend's bounded call ran out;
    * `:no_computer`: placed on the owner's computers, none is connected now;
    * `{:failed, evidence}`: the bus or the server answered with an error, or
      with an answer outside its contract; `evidence` is its words, bounded.
  """
  @type reason ::
          :not_offered
          | :backend_missing
          | :no_server
          | :host_unavailable
          | :not_authorized
          | :timeout
          | :no_computer
          | {:failed, String.t()}

  @typedoc "Which fact decided: this build's host (or the `host:` named), or a named `provider:`."
  @type source :: :build | :given

  @typedoc "Where a notification rings: on this computer, or on the owner's computers."
  @type placement :: :here | :computers

  @type resolution :: %{
          provider: :mac_app | :dbus,
          placement: placement(),
          module: module(),
          source: source()
        }

  @doc """
  Whether a notification could be shown now. A refusal is one clause its
  caller embeds ("… because <refusal>."): no final period, and lowercase
  unless it starts with "Fermix".
  """
  @callback ready(context :: map(), opts :: keyword()) :: :ok | {:error, String.t()}

  @doc "Shows one notification, answering its id or why it did not show."
  @callback post(notification(), opts :: keyword()) :: {:ok, id()} | {:error, reason()}

  @platform "computer"
  @destination "local"

  @doc "The reminder platform this adapter answers to in the delivery channels map."
  @spec platform() :: String.t()
  def platform, do: @platform

  @doc "The one destination a delivery to this computer carries."
  @spec destination() :: String.t()
  def destination, do: @destination

  @doc """
  The backend in force: the provider (`Native.Provider.current/1`, so a caller
  names it with `provider:` or the host that selects it with `host:`), the
  placement (`placement/1`), its module, and which fact decided the provider.
  A provider of `:none` refuses with a sentence naming the build, before the
  placement is read; a placement that cannot be read refuses with its own.
  """
  @spec resolve(keyword()) :: {:ok, resolution()} | {:error, String.t()}
  def resolve(opts) when is_list(opts) do
    with {:ok, provider} <- provider(opts),
         {:ok, placement} <- placement(opts) do
      {:ok,
       %{
         provider: provider,
         placement: placement,
         module: backend(provider, placement),
         source: source(opts)
       }}
    end
  end

  @doc """
  Whether this build offers notifications at all: its provider is not
  `:none`. A fact of the build, read with no I/O and no placement, so what it
  gates (a schema property, a prompt line) is stable for the daemon's life;
  the seams are the provider's (`provider:`, `host:`).
  """
  @spec offered?(keyword()) :: boolean()
  def offered?(opts) when is_list(opts), do: match?({:ok, _provider}, provider(opts))

  @doc """
  Where a notification rings (M99 §10.1): `:computers`, on the owner's
  computers, only on an engine booted as the primary, where Always On is
  available, of a home that is an Always On server's
  (`Home.ServerPrimary.check/2`, which refuses macOS outright); `:here`
  everywhere else. A device or a candidate is always `:here` and reads
  nothing: a desktop whose home moved still holds its own desktop row in
  its retired copy. A device list that cannot be read is an error with its
  clause, never `:here`.

  The facts are read in that order, the device list last. Seams: `placement:`
  names the answer; `role:` (`Home.Role.booted/0`'s role), `always_on:`
  (boolean), `server_primary:` (1-arity, `ServerPrimary.check/2` of a home)
  and `home:` stand in for each fact.
  """
  @spec placement(keyword()) :: {:ok, placement()} | {:error, String.t()}
  def placement(opts) when is_list(opts) do
    case Keyword.fetch(opts, :placement) do
      {:ok, placement} when placement in [:here, :computers] ->
        {:ok, placement}

      {:ok, other} ->
        raise ArgumentError, "placement: must be :here or :computers, got: #{inspect(other)}"

      :error ->
        placed(Keyword.get_lazy(opts, :role, &booted_role/0), opts)
    end
  end

  @doc """
  Whether a notification could be shown now, asked of the resolved backend
  with the turn's tool context. A build that offers none answers its
  `resolve/1` sentence and asks nothing.
  """
  @spec ready(map(), keyword()) :: :ok | {:error, String.t()}
  def ready(context, opts) when is_map(context) and is_list(opts) do
    with {:ok, %{module: module}} <- resolve(opts), do: module.ready(context, opts)
  end

  @doc """
  Shows one notification through the resolved backend. A build that offers
  none answers `:not_offered` and nothing else is tried.
  """
  @spec post(notification(), keyword()) :: {:ok, id()} | {:error, reason()}
  def post(%{title: title, body: body, sound: sound} = notification, opts)
      when is_binary(title) and title != "" and is_binary(body) and is_boolean(sound) and
             is_list(opts) do
    case resolve(opts) do
      {:ok, %{module: module}} -> module.post(notification, opts)
      {:error, sentence} -> {:error, unresolved(sentence, opts)}
    end
  end

  # A build that offers none is `:not_offered`; one whose placement cannot be
  # read fails in that placement's words.
  defp unresolved(sentence, opts),
    do: if(offered?(opts), do: {:failed, sentence}, else: :not_offered)

  @doc """
  The delivery adapter's send, which `Delivery.ChannelSend` dispatches a
  reminder attempt on platform `"computer"` to: one post of `text`, with
  sound, to this computer, the only destination (`destination/0`).

  `opts` are the rail's send options: the event's title as `:title` (the
  summary) is required; the reminder row's id as `:reminder_id` is optional,
  and becomes the notification's; `:proactive_key`, stable across the row's
  retries, becomes its key, which the owner's computers show once and a
  backend on this computer ignores (a notification server keeps no
  idempotency key); the `resolve/1` and backend seams pass through. A failure
  is one error of `Delivery.Error`'s closed vocabulary.
  """
  @spec send_message(String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def send_message(destination, text, opts)
      when is_binary(destination) and is_binary(text) and is_list(opts) do
    with :ok <- this_computer(destination),
         {:ok, title} <- title(opts),
         {:ok, reminder_id} <- optional_id(opts, :reminder_id),
         {:ok, key} <- optional_id(opts, :proactive_key) do
      %{title: title, body: text, sound: true, reminder_id: reminder_id, key: key}
      |> post(opts)
      |> delivered()
    end
  end

  @doc """
  The `Delivery.Error` a backend's reason is (M76 §4.6's table).

  Transient, so the rail's ladder retries it on the same target: the app not
  attached in time and a bounded call that ran out are `:timeout`; no session
  bus or no server owning its name, and no computer of the owner's connected,
  are `:connection_refused`. Permanent: a
  missing grant is `:authorization`; a build or a machine that cannot run the
  backend at all (no provider, `busctl` not installed) is `:adapter_unavailable`,
  since no retry installs a tool; an answer the bus or server refused, or one
  outside its contract, is `:remote_rejected`.
  """
  @spec delivery_error(reason()) :: Error.t()
  def delivery_error(:host_unavailable), do: {:transport, :timeout}
  def delivery_error(:timeout), do: {:transport, :timeout}
  def delivery_error(:no_server), do: {:transport, :connection_refused}
  def delivery_error(:no_computer), do: {:transport, :connection_refused}
  def delivery_error(:not_authorized), do: {:permanent, :authorization}
  def delivery_error(:backend_missing), do: {:permanent, :adapter_unavailable}
  def delivery_error(:not_offered), do: {:permanent, :adapter_unavailable}

  def delivery_error({:failed, evidence}) when is_binary(evidence),
    do: {:permanent, :remote_rejected}

  defp provider(opts) do
    case Provider.current(opts) do
      :none -> {:error, not_offered(Provider.host(opts))}
      provider -> {:ok, provider}
    end
  end

  defp backend(:mac_app, :here), do: MacApp
  defp backend(:dbus, :here), do: DBus
  defp backend(:dbus, :computers), do: Computers

  # An Always On server is Linux (`ServerPrimary` refuses macOS), so only a
  # seam can name this pair.
  defp backend(:mac_app, :computers),
    do: raise(ArgumentError, "a home placed on its computers runs on no Mac app's engine")

  defp source(opts), do: if(Keyword.has_key?(opts, :provider), do: :given, else: :build)

  defp placed(:primary, opts) do
    if Keyword.get_lazy(opts, :always_on, &AlwaysOnRelease.available?/0),
      do: server_placement(opts),
      else: {:ok, :here}
  end

  defp placed(_device_candidate_or_none, _opts), do: {:ok, :here}

  defp server_placement(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
    check = Keyword.get(opts, :server_primary, &ServerPrimary.check/1)

    case check.(home) do
      :server ->
        {:ok, :computers}

      {:not_server, {:device_list, _reason}} ->
        {:error,
         "this home's device list could not be read, so Fermix cannot tell whether a " <>
           "notification rings here or on your computers"}

      {:not_server, _reason} ->
        {:ok, :here}
    end
  end

  defp booted_role do
    case Role.booted() do
      %{role: role} -> role
      nil -> nil
    end
  end

  defp not_offered(%{profile: :standalone_cli, os: :darwin}) do
    "this build (the standalone Fermix, a Homebrew formula or a downloaded binary) shows no " <>
      "notifications on this Mac; the Fermix app does, and fermix migrate-to-app moves this " <>
      "install to it"
  end

  defp not_offered(%{profile: :source, os: :darwin}) do
    "this build (a development run from a source checkout) shows no notifications on this " <>
      "Mac; the Fermix app's own engine does"
  end

  # Only a seam can get here: a `provider: :none` named against a host whose
  # build does offer notifications.
  defp not_offered(host) do
    raise ArgumentError,
          "provider: :none contradicts host #{inspect(host)}, which selects " <>
            inspect(Provider.select(host))
  end

  defp this_computer(@destination), do: :ok

  defp this_computer(destination) do
    Logger.error(
      "A delivery to this computer names another destination: " <>
        inspect(destination, printable_limit: 100)
    )

    {:error, {:permanent, :invalid_destination}}
  end

  defp title(opts) do
    case Keyword.get(opts, :title) do
      title when is_binary(title) and title != "" ->
        {:ok, title}

      _missing ->
        Logger.error("A delivery to this computer carries no event title for its summary")
        {:error, {:permanent, :malformed_request}}
    end
  end

  # The reminder's id, or its key: either absent, or a string that is one.
  defp optional_id(opts, field) do
    case Keyword.get(opts, field) do
      nil ->
        {:ok, nil}

      id when is_binary(id) and id != "" ->
        {:ok, id}

      _invalid ->
        Logger.error("A delivery to this computer carries a #{field} that is not one")
        {:error, {:permanent, :malformed_request}}
    end
  end

  defp delivered({:ok, _id}), do: :ok

  defp delivered({:error, reason}) do
    log_failure(reason)
    {:error, delivery_error(reason)}
  end

  # The one reason whose words the closed vocabulary drops; every other reason
  # is its error kind whole, which the rail persists as the row's `last_error`.
  defp log_failure({:failed, evidence}),
    do: Logger.warning("A notification on this computer failed: #{evidence}")

  defp log_failure(_reason), do: :ok
end
