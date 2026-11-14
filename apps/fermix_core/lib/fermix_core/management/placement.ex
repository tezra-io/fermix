defmodule FermixCore.Management.Placement do
  @moduledoc """
  Which engine answers a management request after a move (M75 §6, B12).

  After its home moved, a desktop's engine runs in the device role and its
  app keeps speaking only the local `daemon.sock`. A request about this
  machine is **device-class** and answered here: the daemon's own handshake,
  its lifecycle, logs, diagnostics and Doctor, the setup page's session,
  computer use, iMessage, an accessory wired to it (M91), the browser's
  installer and the installer of a capability that runs here (computer use's
  helper, Messages'), detection of what is this machine's, and every
  settings section and secret of this computer's own.

  **One rule for settings (M97 §19.3, D28).** The id names the machine: a
  section or secret whose id is `computer` or begins `computer.` is this
  computer's (`computer_id?/1`) and answered here, `settings.get`,
  `settings.apply`, `settings.reload` (by its `section`), `secret.set` and
  `secret.clear` alike; every other id is the home's, which after a move is
  the server, its own machine sections (`machine_sections/0`: its sandbox,
  browser and coding agents) included. One id names one machine, for the read
  and for the write, and the computer decides by the id before it asks the
  server anything. A server that does not say it applies the rule
  (`caps.computer.machine_settings` in its `hello_ack`) is asked for none of
  its machine settings (`server_machine_request?/2`, `older_server/1`), and a
  server refuses a sandbox value from a computer whose `hello` did not say
  it (`older_computer/0`). After a move the notetaker, the local
  speech-to-text and the coding agents run on the server, so their installers
  and detection are the server's too. A job is answered by the engine that
  started it: a linked computer's job ids begin `computer.`, so `job.get` and
  `job.cancel` of one are answered here.

  Everything else is **primary-class**: it configures or reads
  the Fermix that lives on the primary, so a linked device
  (`FermixCore.Home.DesktopLink.linked?/2`) forwards it over the rail
  (`FermixCore.Home.Link`), and a device with no link refuses it as stage 1
  did. A device opens no database (`FermixCore.Home.Role`), so with no link it
  refuses every method of a family whose state is the primary's `memory.db`
  (`database_family?/1`: the cues, their sources, watchers, mandates and
  proposals) as retired (`retired/1`): `primary_unreachable`, as a linked
  desktop's is while its server is out of reach, with the sentence that this
  computer is no longer connected to its server. The home's recovery, enrollment and move are the primary's too
  (`home.snapshots.*`, `home.enroll.open`, `home.enroll.withdraw`,
  `home.enroll.approve`, `home.enroll.deny`, `home.candidates.list`,
  `home.move.readiness`, `home.move.start`): after a move the server holds
  them, and the desktop reaches them only through it. A computer's own link
  (M97 §3.1, §3.3: `computer.join.start`, `computer.join.cancel`,
  `computer.disconnect`) is device-class: it is this computer's.
  Always On's steps (`home.act`) are device-class: a linked desktop takes a
  move back and Restore here itself, and its `home.act` sends the server's
  own steps over the link.

  **Rail-only** (`rail_only?/1`, Always On setup §3.5): the server's steps a
  linked desktop's `home.act` sends (`home.move.readiness`,
  `home.move.start`, `home.enroll.open`, `home.enroll.withdraw`,
  `home.enroll.approve`, `home.enroll.deny`, `home.snapshots.run`,
  `home.restart`) are served only to a desktop's forward (actor
  `{:desktop, _}`) and
  refused on `daemon.sock` by name (`rail_only_refusal/1`): there, `home.act`
  takes the step.

  Two methods are **composed** (`composed?/1`): `home.status` and
  `settings.sections`. A linked device answers them itself and adds the
  primary's own answer, asked within `composed_deadline_ms/0`, or the
  sentence that says why it is missing; the primary answers a forwarded one as
  its own. Two are **decorated** (`decorated?/1`): `setup.state.get` and
  `overview.get` are the server's and forwarded, and a linked device adds the
  step that restarts the server to the restart state they report. The one
  table is this module's; the daemon's dispatch and the
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
  reads what happened from `home.status`. `home.restart` (Restart <server>,
  M97 D28c) is the other: the server restarts right after it answers.
  """

  alias FermixCore.Management.Copy
  alias FermixCore.Management.Protocol

  # The browser's installer installs on this machine, whose browser the
  # server's requests drive here (D28d).
  @device_methods ~w(
    hello diagnostics.build logs.query setup.session.create browser.install.start
    home.status settings.sections home.act
    computer.join.start computer.join.cancel computer.disconnect
  )
  # `accessories.`: an accessory is wired to the computer that answers (M91).
  # `computer.`: this computer's own record of what its server did here
  # (M97 §6.3); it does not match `computer_use.`.
  @device_families ~w(lifecycle. doctor. computer_use. imessage. accessories. computer.)
  # The primary-class families whose state is the primary's memory.db, which
  # a device never opens: one with no link refuses them as retired.
  @database_families ~w(cues.)
  @rail_only_methods ~w(home.move.readiness home.move.start home.enroll.open home.enroll.withdraw
                        home.enroll.approve home.enroll.deny home.snapshots.run home.restart)
  @rail_only_sentence "Always On takes this step itself: send home.act with the action the " <>
                        "summary offers."
  # Answered on this machine with the primary's own answer added (M75: a
  # desktop draws its own facts beside the server's).
  @composed_methods ~w(home.status settings.sections)
  # How long a composed answer waits for the primary's part: well inside the
  # apps' 10 s management call timeout, so the device's own part always
  # arrives.
  @composed_deadline_ms 5_000

  # The one rule for settings and secrets (M97 §19.3, D28): the id names the
  # machine. A section or a secret whose id is `computer` or begins
  # `computer.` is this computer's, answered here; every other id is the
  # home's, which after a move is the server, its own machine sections
  # included. A dot, since `computer_use` and `computer_history` are plain ids
  # that already begin `computer_`. `settings.reload` names the section an
  # outside edit was refused for, so a computer clears its own here.
  @computer_id "computer"
  @computer_prefix "computer."
  @section_methods ~w(settings.get settings.apply settings.reload)
  @secret_methods ~w(secret.set secret.clear)
  # A job is answered by the engine that started it: a linked computer's own
  # ids name it (`computer.job:<id>`, `Management.Jobs`).
  @job_methods ~w(job.get job.cancel)
  # The sections that describe a machine rather than the home: the sandbox its
  # commands run in, its browser (D28d), whether coding agents may run on it
  # (M98 D5), computer use of its screen, its part of the screen history (M97
  # §4), the accessory link to a Mac's USB ports. They name the machine in
  # their titles, and a write of one is an owner decision. `computer` (what
  # Fermix on the server may use on this computer, §7.2) is this computer's
  # by the rule itself.
  @machine_sections ~w(sandbox browser harness_machine computer_use computer_history accessories)
  # A sandbox value, the server's (`env:`) or this computer's (`computer.env:`).
  @env_prefix "env:"
  # An installer installs on the machine that runs its feature: after a move
  # the notetaker and the local speech-to-text run on the server; computer
  # use's helper and Messages' run on this computer.
  @home_install_targets ~w(meetbot local_stt)
  # What `setup.detect` probes for the home (the coding agents the server runs,
  # the provider sign-ins it imports, a local model server, the notetaker); a
  # request for only these is the server's, any other is this machine's.
  @home_detect_targets ~w(claude_code codex_cli ollama harness_vendors meetbot)
  # Forwarded, and answered with the step that restarts the server added
  # (`Fermix.CLI.Daemon`): the restart state they report is the server's.
  @decorated_methods ~w(setup.state.get overview.get)
  @older_server_sentence " runs an older Fermix, which takes its own sandbox and coding " <>
                           "settings only on the server. It updates on its own."
  @older_computer_sentence "Update Fermix on this computer to change its sandbox values."

  @device_class_sentence "This request configures the computer it came from, so the " <>
                           "server does not answer it."
  @too_old_sentence "The server runs a newer Fermix than this computer can talk to, so " <>
                      "update Fermix on this computer."
  @behind_sentence "The server runs an older Fermix than this computer. It updates on its " <>
                     "own once the app for each computer that keeps your backups carries the " <>
                     "newer one."

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
  # start restarts the primary into the move right after it answers, and
  # Restart <server> (M97 D28c) restarts it right after it answers too.
  @unconfirmed_methods ~w(home.move.start home.restart)

  @typedoc "Which engine answers a request."
  @type place :: :device | :primary

  @doc "Where `method` with `params` is answered: this machine, or the primary."
  @spec place(String.t(), map()) :: place()
  def place(method, params) when is_binary(method) and is_map(params) do
    cond do
      method in @device_methods -> :device
      Enum.any?(@device_families, &String.starts_with?(method, &1)) -> :device
      true -> by_params(method, params)
    end
  end

  # The methods placed by what they name: a section, a secret or a job by its
  # id, an install by its target, a detection by its targets.
  defp by_params(method, params) when method in @section_methods, do: by_id(params["section"])
  defp by_params(method, params) when method in @secret_methods, do: by_id(params["id"])
  defp by_params(method, params) when method in @job_methods, do: by_id(params["job_id"])
  defp by_params("capabilities.install.start", params), do: by_install(params["target"])
  defp by_params("setup.detect", params), do: by_detect(params["targets"])
  defp by_params(_method, _params), do: :primary

  defp by_id(id), do: if(computer_id?(id), do: :device, else: :primary)
  defp by_install(target), do: if(target in @home_install_targets, do: :primary, else: :device)

  defp by_detect([_ | _] = targets),
    do: if(Enum.all?(targets, &(&1 in @home_detect_targets)), do: :primary, else: :device)

  defp by_detect(_targets), do: :device

  @doc """
  Whether a settings section or secret `id` is this computer's: `computer`,
  or one that begins `computer.` (§19.3).
  """
  @spec computer_id?(term()) :: boolean()
  def computer_id?(@computer_id), do: true
  def computer_id?(@computer_prefix <> rest), do: rest != ""
  def computer_id?(_id), do: false

  @doc """
  The plain id a computer's own id names here: `computer.sandbox` is this
  computer's `sandbox`, `computer.env:LEDGER_TOKEN` its `env:LEDGER_TOKEN`;
  `computer` is itself.
  """
  @spec plain_id(String.t()) :: String.t()
  def plain_id(@computer_id), do: @computer_id
  def plain_id(@computer_prefix <> rest) when rest != "", do: rest

  @doc "The id this computer publishes its own `plain` id under: `plain_id/1`'s inverse."
  @spec computer_id(String.t()) :: String.t()
  def computer_id(@computer_id), do: @computer_id
  def computer_id(plain) when is_binary(plain) and plain != "", do: @computer_prefix <> plain

  @doc "The sections that describe a machine rather than the home."
  @spec machine_sections() :: [String.t()]
  def machine_sections, do: @machine_sections

  @doc "Whether the plain section `id` describes a machine."
  @spec machine_section?(term()) :: boolean()
  def machine_section?(id), do: id in @machine_sections

  @doc """
  Whether `method` with `params` writes a machine's own settings, the
  server's or this computer's: a write of a machine section or of
  `computer` and `computer.<id>`, or a sandbox value set or cleared
  (`env:<NAME>`, `computer.env:<NAME>`). On `daemon.sock` each is an owner
  decision (`Fermix.CLI.Daemon`).
  """
  @spec machine_write?(String.t(), map()) :: boolean()
  def machine_write?("settings.apply", %{"section" => section}) when is_binary(section),
    do: computer_id?(section) or machine_section?(section)

  def machine_write?(method, %{"id" => id}) when method in @secret_methods and is_binary(id),
    do: sandbox_value?(id)

  def machine_write?(_method, _params), do: false

  defp sandbox_value?(@env_prefix <> _name), do: true
  defp sandbox_value?(@computer_prefix <> @env_prefix <> _name), do: true
  defp sandbox_value?(_id), do: false

  @doc """
  Whether the server answers `method` with `params` only where it applies
  §19.3's rule (`caps.computer.machine_settings`): a plain machine section,
  read or written, or a sandbox value of the server's (`env:`). A server
  without the rule refuses them; a computer asks it for none
  (`older_server/1`).
  """
  @spec server_machine_request?(String.t(), map()) :: boolean()
  def server_machine_request?(method, %{"section" => section}) when method in @section_methods,
    do: machine_section?(section)

  def server_machine_request?(method, %{"id" => @env_prefix <> _name})
      when method in @secret_methods,
      do: true

  def server_machine_request?(_method, _params), do: false

  @doc """
  A linked computer's answer to a request for its server's machine settings
  while the server runs a Fermix without §19.3's rule: `unavailable`, naming
  the server when its name is known.
  """
  @spec older_server(String.t() | nil) :: Protocol.route_result()
  def older_server(name) when is_binary(name) or is_nil(name),
    do:
      {:error, :unavailable,
       %{
         "capability" => "settings",
         "sentence" => (name || "Your server") <> @older_server_sentence
       }}

  @doc """
  The server's refusal of a sandbox value (`env:`) a computer without §19.3's
  rule sent: such a computer answers its own machine sections itself, so the
  one it sends is a value typed in its own Sandbox pane, which is not the
  server's.
  """
  @spec older_computer() :: Protocol.route_result()
  def older_computer,
    do:
      {:error, :unavailable,
       %{"capability" => "settings", "sentence" => @older_computer_sentence}}

  @doc """
  Whether a linked computer forwards `method` and adds to the server's answer
  the step that restarts the server (`setup.state.get`, `overview.get`).
  """
  @spec decorated?(String.t()) :: boolean()
  def decorated?(method) when is_binary(method), do: method in @decorated_methods

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
  its answer, or the sentence a person is shown for why it is missing;
  `{:too_old, sentence}` when the primary refused this engine's protocol as
  too old (`client_too_old`), so the summary asks for an update, and
  `{:behind, sentence}` when it refused it as newer than its own
  (`daemon_too_old`: this computer updated first, and the server updates on
  its own once the app for each computer that keeps the backups carries the
  newer release, M97 §3.4), so the summary says so.
  """
  @spec primary_part((Protocol.request(), keyword() -> Protocol.route_result()), String.t()) ::
          {:ok, map()} | {:missing, String.t()} | {:too_old, String.t()} | {:behind, String.t()}
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
      {:error, :client_too_old, _details} -> {:too_old, @too_old_sentence}
      {:error, :daemon_too_old, _details} -> {:behind, @behind_sentence}
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

  defp unconfirmed_sentence("home.restart", name) do
    "#{server(name)} was asked to restart and did not confirm it in time. Always On shows " <>
      "how it stands once the server is back."
  end

  defp server(name) when is_binary(name), do: "The server #{name}"
  defp server(nil), do: "The server"

  @doc """
  The methods served only to a desktop's forward over the rail, and refused
  on `daemon.sock` by name (the moduledoc's *Rail-only*).
  """
  @spec rail_only_methods() :: [String.t()]
  def rail_only_methods, do: @rail_only_methods

  @doc "Whether `method` is served only to a desktop's forward."
  @spec rail_only?(String.t()) :: boolean()
  def rail_only?(method) when is_binary(method), do: method in @rail_only_methods

  @doc """
  The refusal of a rail-only `method` sent by anything but a desktop's
  forward: `unavailable`, naming the method, with the sentence that says
  `home.act` takes the step.
  """
  @spec rail_only_refusal(String.t()) :: Protocol.route_result()
  def rail_only_refusal(method) when method in @rail_only_methods do
    {:error, :unavailable,
     %{"capability" => "home", "method" => method, "sentence" => @rail_only_sentence}}
  end

  @doc "The methods answered on this machine whatever their parameters."
  @spec device_methods() :: [String.t()]
  def device_methods,
    do: Enum.filter(Protocol.methods(), &(place(&1, %{}) == :device))

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

  @doc """
  Whether `method` belongs to a primary-class family whose state is the
  primary's `memory.db` (see the moduledoc).
  """
  @spec database_family?(String.t()) :: boolean()
  def database_family?(method) when is_binary(method),
    do: Enum.any?(@database_families, &String.starts_with?(method, &1))

  @doc """
  The refusal of a device with no link to its server (retired) for a method of
  a `database_family?/1`: `primary_unreachable` with the summary's own retired
  sentence for this computer, `os_type` as `:os.type/0` answers it.
  """
  @spec retired({atom(), atom()}) :: Protocol.route_result()
  def retired({_family, name} = os_type) when is_tuple(os_type) and is_atom(name) do
    machine = if os_type == {:unix, :darwin}, do: "Mac", else: "computer"
    unreachable(nil, Copy.summary_sentence(:retired, %{machine: machine}))
  end

  @doc "The primary's refusal of a device-class request a desktop forwarded."
  @spec device_class_refusal(String.t()) :: Protocol.route_result()
  def device_class_refusal(method) when is_binary(method),
    do:
      {:error, :device_class_method, %{"method" => method, "sentence" => @device_class_sentence}}
end
