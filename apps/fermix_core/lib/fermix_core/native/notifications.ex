defmodule FermixCore.Native.Notifications do
  @moduledoc """
  Notifications on this computer (M76 §4.3, §4.6): the service, the behaviour
  its backends implement, and the delivery adapter the reminder rail resolves
  for platform `"computer"`.

  `resolve/1` is the only place a backend is chosen, from `Native.Provider`:
  `Notifications.DBus` where the provider is `:dbus`. A build whose provider is
  `:none` (a standalone engine or a source run on a Mac) has no backend and
  refuses with a sentence naming the build, as `PlaceSearch.Backend` names a
  build without the Apple Maps helper. Nothing substitutes another backend: no
  `osascript`, no `notify-send`, no poster of the engine's own.

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
  alias FermixCore.Native.Notifications.DBus
  alias FermixCore.Native.Provider

  @typedoc "One notification: its summary, its body, and whether it rings with sound."
  @type notification :: %{title: String.t(), body: String.t(), sound: boolean()}

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
          | {:failed, String.t()}

  @typedoc "Which fact decided: this build's host (or the `host:` named), or a named `provider:`."
  @type source :: :build | :given
  @type resolution :: %{provider: :mac_app | :dbus, module: module(), source: source()}

  @doc "Whether a notification could be shown now; a refusal is one sentence."
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
  names it with `provider:` or the host that selects it with `host:`), its
  module, and which fact decided. A provider of `:none` refuses with a
  sentence naming the build.
  """
  @spec resolve(keyword()) :: {:ok, resolution()} | {:error, String.t()}
  def resolve(opts) when is_list(opts) do
    case Provider.current(opts) do
      :none -> {:error, not_offered(Provider.host(opts))}
      provider -> {:ok, %{provider: provider, module: backend(provider), source: source(opts)}}
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
      {:error, _sentence} -> {:error, :not_offered}
    end
  end

  @doc """
  The delivery adapter's send, which `Delivery.ChannelSend` dispatches a
  reminder attempt on platform `"computer"` to: one post of `text`, with
  sound, to this computer, the only destination (`destination/0`).

  `opts` are the rail's send options: the event's title as `:title` (the
  summary) is required; `:proactive_key` goes unused, since a notification
  server keeps no idempotency key; the `resolve/1` and backend seams pass
  through. A failure is one error of `Delivery.Error`'s closed vocabulary.
  """
  @spec send_message(String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def send_message(destination, text, opts)
      when is_binary(destination) and is_binary(text) and is_list(opts) do
    with :ok <- this_computer(destination),
         {:ok, title} <- title(opts) do
      %{title: title, body: text, sound: true}
      |> post(opts)
      |> delivered()
    end
  end

  @doc """
  The `Delivery.Error` a backend's reason is (M76 §4.6's table).

  Transient, so the rail's ladder retries it on the same target: the app not
  attached in time and a bounded call that ran out are `:timeout`; no session
  bus or no server owning its name is `:connection_refused`. Permanent: a
  missing grant is `:authorization`; a build or a machine that cannot run the
  backend at all (no provider, `busctl` not installed) is `:adapter_unavailable`,
  since no retry installs a tool; an answer the bus or server refused, or one
  outside its contract, is `:remote_rejected`.
  """
  @spec delivery_error(reason()) :: Error.t()
  def delivery_error(:host_unavailable), do: {:transport, :timeout}
  def delivery_error(:timeout), do: {:transport, :timeout}
  def delivery_error(:no_server), do: {:transport, :connection_refused}
  def delivery_error(:not_authorized), do: {:permanent, :authorization}
  def delivery_error(:backend_missing), do: {:permanent, :adapter_unavailable}
  def delivery_error(:not_offered), do: {:permanent, :adapter_unavailable}

  def delivery_error({:failed, evidence}) when is_binary(evidence),
    do: {:permanent, :remote_rejected}

  # The Mac app's backend arrives with the `native_host` wire (§4.4); until
  # then a `:mac_app` provider has no clause here and raises.
  defp backend(:dbus), do: DBus

  defp source(opts), do: if(Keyword.has_key?(opts, :provider), do: :given, else: :build)

  defp not_offered(%{profile: :standalone_cli, os: :darwin}) do
    "this build (the standalone Fermix, a Homebrew formula or a downloaded binary) shows no " <>
      "notifications on this Mac; the Fermix app does, and fermix migrate-to-app moves this " <>
      "install to it"
  end

  defp not_offered(%{profile: :source, os: :darwin}) do
    "this build (a development run from a source checkout) shows no notifications on this " <>
      "Mac; the Fermix app's own engine does"
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
