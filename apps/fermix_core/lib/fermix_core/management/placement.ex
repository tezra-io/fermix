defmodule FermixCore.Management.Placement do
  @moduledoc """
  Which engine answers a management request after a move (M75 §6, B12).

  After its home moved, a desktop's engine runs in the device role and its
  app keeps speaking only the local `daemon.sock`. A request about this
  machine is **device-class** and answered here: the daemon's own handshake,
  its lifecycle, logs, diagnostics and Doctor, the setup page's session and
  detection, computer use, iMessage, the browser and capability installers,
  and `settings.get` or `settings.apply` for a section that configures only
  this machine. Everything else is **primary-class**: it configures or reads
  the Fermix that lives on the primary, so a linked device
  (`FermixCore.Home.DesktopLink.linked?/2`) forwards it over the rail
  (`FermixCore.Home.Link`), and a device with no link refuses it as stage 1
  did. The home's recovery, enrollment and move are the primary's too
  (`home.snapshots.*`, `home.enroll.open`, `home.candidates.list`,
  `home.move.readiness`, `home.move.start`): after a move the server holds
  them, and the desktop reaches them only through it. The Always On
  provisioner (`home.provision.*`) is device-class: its token and the ledger
  of what it created stay on the computer that created the server, which
  manages that server itself and never sends the request to it.

  Two methods are **composed** (`composed?/1`): `home.status` and
  `settings.sections`. A linked device answers them itself and adds the
  primary's own answer, asked within `composed_deadline_ms/0`, or the
  sentence that says why it is missing; the primary answers a forwarded one as
  its own. The one table is this module's; the daemon's dispatch and the
  primary's refusal of a forwarded device-class request both read it.

  The primary answers a forwarded request as `daemon.sock` would, with the
  authority of the owner's app (the desktop placed its own caller before
  forwarding), and refuses a device-class one with `device_class_method`:
  it belongs to the desktop that sent it.

  A desktop waits for the primary's answer at most `forward_deadline_ms/1`:
  8 s, inside the apps' 10 s call timeout, and 60 s for `home.move.readiness`
  and `home.move.start`, which walk the whole home on the primary before they
  answer (`priv/management/PROTOCOL.md` publishes both, and a client gives
  those two calls a longer timeout of its own). A request whose effect may
  stand though its answer was lost (`home.move.start`: the primary restarts
  into the move right after answering) is answered `unconfirmed` when the
  answer does not arrive (`unconfirmed/2`), never as a failure: the caller
  reads what happened from `home.status`.
  """

  alias FermixCore.Management.Protocol

  @device_methods ~w(
    hello diagnostics.build logs.query setup.session.create setup.detect
    browser.install.start capabilities.install.start
    home.status settings.sections
  )
  @device_families ~w(lifecycle. doctor. computer_use. imessage. home.provision.)
  # Answered on this machine with the primary's own answer added (M75: a
  # desktop draws its own facts beside the server's).
  @composed_methods ~w(home.status settings.sections)
  # How long a composed answer waits for the primary's part: well inside the
  # apps' 10 s management call timeout, so the device's own part always
  # arrives.
  @composed_deadline_ms 5_000

  # The settings sections that configure only this machine: the sandbox its
  # commands run in, computer use of this screen, this screen's history, and
  # this Mac's Messages.
  @device_sections ~w(sandbox computer_use computer_history channels.imessage)
  @section_methods ~w(settings.get settings.apply)

  @device_class_sentence "This request configures the computer it came from, so the " <>
                           "server does not answer it."

  # How long a desktop waits for the primary's answer to a forwarded request:
  # well inside the apps' 10 s call timeout, except the two calls that walk the
  # whole home on the primary before they answer (the move's readiness
  # report). Measured on a Mac: homes of 3 and 4 GiB (19,681 and 28,789
  # files) walked in 1 to 3 s, and the slowest first walk seen took 0.41 ms a
  # file, so a home at the archive's 100,000-file bound walks in about 41 s;
  # 60 s leaves room for its free-space check (5 s at most) and the keychain.
  @forward_deadline_ms 8_000
  @home_walk_deadline_ms 60_000
  @forward_deadlines %{
    "home.move.readiness" => @home_walk_deadline_ms,
    "home.move.start" => @home_walk_deadline_ms
  }
  # Requests whose effect may stand though their answer was lost: the move's
  # start restarts the primary into the move right after it answers.
  @unconfirmed_methods ~w(home.move.start)

  @typedoc "Which engine answers a request."
  @type place :: :device | :primary

  @doc "Where `method` with `params` is answered: this machine, or the primary."
  @spec place(String.t(), map()) :: place()
  def place(method, params) when is_binary(method) and is_map(params) do
    cond do
      method in @device_methods -> :device
      Enum.any?(@device_families, &String.starts_with?(method, &1)) -> :device
      method in @section_methods and params["section"] in @device_sections -> :device
      true -> :primary
    end
  end

  @doc """
  Whether `method` is composed: answered on this machine, which adds the
  primary's answer to its own on a linked device, and answered by the primary
  as its own when a desktop forwards it.
  """
  @spec composed?(String.t()) :: boolean()
  def composed?(method) when is_binary(method), do: method in @composed_methods

  @doc "How long a composed answer waits for the primary's part, in milliseconds."
  @spec composed_deadline_ms() :: pos_integer()
  def composed_deadline_ms, do: @composed_deadline_ms

  @doc """
  Whether the primary serves `method` with `params` when a desktop forwards
  it: every primary-class request, and the composed ones.
  """
  @spec served_forwarded?(String.t(), map()) :: boolean()
  def served_forwarded?(method, params) when is_binary(method) and is_map(params),
    do: place(method, params) == :primary or composed?(method)

  @doc """
  Asks the primary for its part of a composed answer (`method`, no params)
  through `forward`, the daemon's link to it, within `composed_deadline_ms/0`:
  its answer, or the sentence a person is shown for why it is missing.
  """
  @spec primary_part((Protocol.request(), keyword() -> Protocol.route_result()), String.t()) ::
          {:ok, map()} | {:missing, String.t()}
  def primary_part(forward, method)
      when is_function(forward, 2) and method in @composed_methods do
    request = %{
      request_id: "composed-" <> method,
      protocol_version: Protocol.protocol_version(),
      method: method,
      params: %{}
    }

    case forward.(request, deadline_ms: @composed_deadline_ms) do
      {:ok, %{} = answer} -> {:ok, answer}
      {:error, _code, %{"sentence" => sentence}} when is_binary(sentence) -> {:missing, sentence}
      {:error, code, _details} -> {:missing, "The server did not answer this (#{code})."}
    end
  end

  @doc """
  How long a desktop waits for the primary's answer to a forwarded `method`,
  in milliseconds: 8 s, and 60 s for the two calls that walk the whole home
  before they answer (`home.move.readiness`, `home.move.start`).
  """
  @spec forward_deadline_ms(String.t()) :: pos_integer()
  def forward_deadline_ms(method) when is_binary(method),
    do: Map.get(@forward_deadlines, method, @forward_deadline_ms)

  @doc "The forwarded methods a desktop waits longer than 8 s for, with their deadlines in milliseconds."
  @spec long_forward_deadlines() :: %{String.t() => pos_integer()}
  def long_forward_deadlines, do: @forward_deadlines

  @doc """
  Whether a forwarded `method` may have taken effect on the primary though its
  answer never arrived, so a lost answer is `unconfirmed/2` and no failure.
  """
  @spec unconfirmed_on_loss?(String.t()) :: boolean()
  def unconfirmed_on_loss?(method) when is_binary(method), do: method in @unconfirmed_methods

  @doc """
  The answer to a forwarded `method` the primary received but whose answer was
  lost (its deadline passed, or the session ended under it): `unconfirmed`,
  naming the method and the primary when known, with the sentence that says
  where its outcome shows.
  """
  @spec unconfirmed(String.t() | nil, String.t()) :: Protocol.route_result()
  def unconfirmed(name, method)
      when (is_binary(name) or is_nil(name)) and method in @unconfirmed_methods do
    details = %{"method" => method, "sentence" => unconfirmed_sentence(method, name)}
    details = if name, do: Map.put(details, "primary", name), else: details
    {:error, :unconfirmed, details}
  end

  defp unconfirmed_sentence("home.move.start", name) do
    "#{server(name)} did not confirm in time whether the move started. Its state shows " <>
      "once the server answers again, and starting it again never starts a second move."
  end

  defp server(name) when is_binary(name), do: "The server #{name}"
  defp server(nil), do: "The server"

  @doc "The methods answered on this machine whatever their parameters."
  @spec device_methods() :: [String.t()]
  def device_methods,
    do: Enum.filter(Protocol.methods(), &(place(&1, %{}) == :device))

  @doc "The settings sections that configure only this machine."
  @spec device_sections() :: [String.t()]
  def device_sections, do: @device_sections

  @doc """
  The sentence a person is shown while the primary cannot be reached,
  naming it when its name is known.
  """
  @spec unreachable_sentence(String.t() | nil) :: String.t()
  def unreachable_sentence(name) when is_binary(name) and name != "",
    do: "The server #{name} is unreachable. Fermix keeps your message until it is back."

  def unreachable_sentence(nil),
    do: "Fermix cannot reach its server. Fermix keeps your message until it is back."

  @doc """
  The management refusal of a forwarded request while the primary cannot be
  reached: `primary_unreachable`, its sentence, and the primary's name when
  known.
  """
  @spec unreachable(String.t() | nil, String.t()) :: Protocol.route_result()
  def unreachable(name, sentence)
      when (is_binary(name) or is_nil(name)) and is_binary(sentence) do
    details = %{"sentence" => sentence}
    details = if name, do: Map.put(details, "primary", name), else: details
    {:error, :primary_unreachable, details}
  end

  @doc "The primary's refusal of a device-class request a desktop forwarded."
  @spec device_class_refusal(String.t()) :: Protocol.route_result()
  def device_class_refusal(method) when is_binary(method),
    do:
      {:error, :device_class_method, %{"method" => method, "sentence" => @device_class_sentence}}
end
