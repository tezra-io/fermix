defmodule FermixCore.Home.Role do
  @moduledoc """
  The role this engine runs a home in (M75 D13): `primary`, `device` or
  `candidate`.

  The primary runs the agent loop, its schedulers and its channels, and is the
  one engine that writes the home's long-term memory. A device serves the
  desktop app beside it and runs nothing that produces a turn, writes
  long-term memory or calls a provider: after a move the token file on its host
  is a retired copy, and a rotating refresh token has one live owner (M75 D5).
  A candidate (M75 §2, B4) is a fresh engine waiting to become the primary
  through a move: it enrolls with the primary, then waits for the move, and
  starts nothing else (`children/2` keeps only `candidate_keeps/0`). It never
  initialises a primary epoch and never opens `memory.db`. One binary, three
  roles.

  **Configuration.** `[fermix_core.engine] role = "primary" | "device" |
  "candidate"` in
  `config.toml`, read through `FermixCore.Setup.ConfigStore` like every other
  section: `normalize/1` turns the file's strings into atoms at the parse
  boundary and refuses anything else by name, and `to_keyword/1` is the inverse
  the persist path writes (the "Config round-trips" rule). An absent section is
  the primary, so a fresh install and an upgraded one run as the primary with
  no new configuration.

  **The moved marker.** A home that carries `FermixCore.Home.Moved`'s marker
  has moved to another host and refuses to boot as the primary (`resolve/2`):
  it runs only in the device role, or is replaced by a snapshot restored into
  an empty home. A marker that cannot be read refuses the primary role too,
  with its own named error. The device role does not consult the marker to
  decide; it reads it once only to say where the primary went. Nor does the
  candidate: `fermix home enroll` refuses a home with a marker, and a candidate
  is never the primary until its move renames a restored home into place.

  **Read once.** `remember!/2` resolves the role when the engine boots, before
  any child starts, and records it; a moved home raises there with one
  sentence (`error_sentence/1`) and the boot fails. `current/0` and
  `recorded/0` read that record, and raise in a process that booted no engine;
  `booted/0` is the read for code that also runs in such a process (a tree-less
  CLI verb), where it is `nil`. A caller that needs another role in a test is
  handed a record instead.

  **Tree-less verbs.** A CLI verb that boots no engine and would sign in, sign
  out, refresh or import a login asks `admit_configured/1`: the role the home is
  configured for, read through the settings file's own parse, and the marker.
  A moved home is refused there like a device, since the verb would reach the
  retired copy of the primary's tokens.

  **One policy for both applications.** `primary_only_reasons/0` is the one
  list of supervised children a device boot leaves out, each with why,
  `device_only_reasons/0` the children only a device starts (the desktop
  relay's tree), and `children/2` is the one filter `FermixCore.Application` and
  `FermixChannels.Application` run their child lists through (`FermixWeb.Application`
  too, for a candidate): a candidate keeps only `candidate_keeps/0`. `admit/1`
  is the one refusal a device or a candidate returns wherever it is asked for
  a turn, a provider call, a token or a long-term memory write:
  `{:device_role, sentence}` for both, the refusal every caller already shows,
  with a sentence that names the role.
  """

  alias FermixCore.Home.Moved
  alias FermixCore.Setup.ConfigStore

  require Logger

  @record_key {__MODULE__, :boot}
  @section "[fermix_core.engine]"
  @config_keys ["role"]

  # Every child a device-role engine leaves out, with the reason. Everything
  # else in both trees is kept: management and the daemon socket, the
  # companion and browser-host sockets, the native host, computer-history
  # capture and its purge, the turn queue (whose turns `admit/1` refuses),
  # sandbox, secrets, health, logging and trace.
  @primary_only [
    {FermixCore.Jobs.RunnerSupervisor, "runs a scheduled job's turn"},
    {FermixCore.Jobs.Scheduler, "fires scheduled jobs into turns"},
    {FermixCore.Temporal.Scheduler, "fires reminders"},
    {FermixCore.Temporal.DeliverySupervisor, "delivers a fired reminder to a channel"},
    {FermixCore.OpenLoops.Scheduler, "scans open loops and starts their check-ins"},
    {FermixCore.OpenLoops.CheckInSupervisor, "runs an open loop's check-in turn"},
    {FermixCore.Harness.Supervisor,
     "reconciles coding runs and delivers a finished one as a continuation turn"},
    {FermixCore.SkillCuration.Scheduler, "curates skills from conversations"},
    {FermixCore.Cues.Supervisor, "admits outside cues that start turns"},
    {FermixCore.Meetings.Supervisor,
     "joins a meeting only from a turn and settles the primary's meeting rows"},
    {FermixChannels.Channels.Telegram.Poller, "polls Telegram into turns"},
    {FermixChannels.Channels.Discord.Gateway, "takes Discord messages into turns"},
    {FermixChannels.Channels.Slack.SocketMode, "takes Slack events into turns over Socket Mode"},
    {FermixChannels.Channels.Signal.Listener, "takes Signal messages into turns"},
    {FermixChannels.Channels.IMessage.Supervisor, "takes iMessages into turns"},
    {FermixChannels.Channels.Acp.Supervisor, "runs an ACP client's prompts as turns"},
    {FermixChannels.Mobile.Supervisor,
     "admits phone turns through the identity bundle, which moved with the primary"},
    {FermixChannels.Voice.CallRowSweep,
     "settles the rows and detached tasks the primary's calls owe"},
    {FermixCore.Auth.TokenSupervisor,
     "the token file here is a retired copy; refreshing it would invalidate the primary's"},
    {FermixCore.Realtime.Supervisor,
     "a realtime session calls a provider with this host's token; a device's voice " <>
       "comes back through the primary"},
    {FermixChannels.Voice.Supervisor,
     "routes realtime delegations, and a device runs no realtime session"},
    {FermixCore.ComputerHistory.Summarizer.Scheduler,
     "summarizes captured history with a provider; capture and its purge stay"},
    {FermixCore.Home.Snapshot.Scheduler,
     "writes the primary's snapshots; a device's home is a retired copy, and the move " <>
       "captures its own"},
    {FermixChannels.Home.Enrollment,
     "holds the enrollment window a candidate primary enrolls through; only the primary " <>
       "can be moved"}
  ]

  @primary_only_modules Enum.map(@primary_only, &elem(&1, 0))

  # Every child only a device-role engine starts, with the reason. The
  # primary never starts them (M75 §2).
  @device_only [
    {FermixChannels.Desktop.DeviceSupervisor,
     "dials the primary from a desktop whose home moved, and carries the move from its source"}
  ]

  @device_only_modules Enum.map(@device_only, &elem(&1, 0))

  # Every child a candidate starts, with the reason; everything else in the
  # three trees is left out (M75 §2). A keep list rather than a drop list, so a
  # child added later never starts on a candidate by default.
  @candidate_keeps [
    {FermixCore.CommandHost.Supervisor,
     "the command host the offer's free-space check (df) and the restore's keyring probe " <>
       "(busctl) run under"},
    {Task.Supervisor, "the task supervisor the candidate's enrollment and restore run under"},
    {FermixCore.Trace, "the run trace the move's lifecycle events are recorded in"},
    {FermixCore.Management.Lifecycle, "the daemon's one stop path, which restarts it"},
    {Fermix.CLI.Daemon, "daemon.sock, which answers home.status and refuses the rest"},
    {FermixChannels.Home.CandidateSupervisor,
     "the candidate: its enrollment with the primary and the move it waits for"},
    {FermixWebWeb.Telemetry, "the web application's metrics registry, which serves nothing"},
    {DNSCluster, "the web application's cluster lookup, off unless configured"},
    {Phoenix.PubSub, "the web application's PubSub, which serves nothing"}
  ]

  @candidate_keep_modules Enum.map(@candidate_keeps, &elem(&1, 0))

  # Children only a candidate starts: the primary and a device leave them out.
  @candidate_only_modules [FermixChannels.Home.CandidateSupervisor]

  @type role :: :primary | :device | :candidate
  @type record :: %{role: role(), primary: String.t() | nil}
  @type error ::
          {:home_moved, Moved.marker()}
          | {:invalid_marker, Path.t(), term()}
          | {:file, Path.t(), File.posix()}
          | {:config, Path.t(), File.posix() | String.t()}
  @type refusal :: {:device_role, String.t()}
  @type child :: Supervisor.child_spec() | {module(), term()} | module()

  @doc """
  The role `root` runs in under `config`, the `[fermix_core.engine]` section in
  any of its shapes: the device whenever the section says so, otherwise the
  primary, unless the home carries the moved marker or one that cannot be read.
  """
  @spec resolve(Path.t(), keyword() | map() | nil) :: {:ok, role()} | {:error, error()}
  def resolve(root, config) when is_binary(root) and root != "" do
    case configured_role(config) do
      :device -> {:ok, :device}
      :candidate -> {:ok, :candidate}
      :primary -> primary(Moved.read(root))
    end
  end

  defp primary(:absent), do: {:ok, :primary}
  defp primary({:ok, marker}), do: {:error, {:home_moved, marker}}
  defp primary({:error, reason}), do: {:error, reason}

  defp configured_role(config), do: config |> normalize() |> Keyword.get(:role, :primary)

  @doc """
  What a boot of `root` records: its role and, for a device, where the marker
  says the primary went (`nil` when there is no marker to say).
  """
  @spec boot(Path.t(), keyword() | map() | nil) :: {:ok, record()} | {:error, error()}
  def boot(root, config) when is_binary(root) and root != "" do
    case resolve(root, config) do
      {:ok, :primary} -> {:ok, %{role: :primary, primary: nil}}
      {:ok, :device} -> {:ok, %{role: :device, primary: primary_name(root)}}
      {:ok, :candidate} -> {:ok, %{role: :candidate, primary: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp primary_name(root), do: root |> Moved.read() |> marker_primary()

  # The device decides without the marker, so one it cannot read costs only the
  # name in a refusal; it is logged rather than refusing the safe role.
  defp marker_primary({:ok, %{to: to}}), do: to
  defp marker_primary(:absent), do: nil

  defp marker_primary({:error, reason}) do
    Logger.error("device role: the moved marker gives no primary: #{inspect(reason)}")
    nil
  end

  @doc """
  Whether a process that booted no engine (a tree-less CLI verb) may sign in,
  sign out, refresh or import a login against `home`: refused as `admit/1`
  refuses a device when the home is configured as one or carries the moved
  marker, refused with the marker's own error when it cannot be read, and
  admitted otherwise. A home with no settings file and no marker is the primary.
  """
  @spec admit_configured(Path.t()) :: :ok | {:error, refusal() | error()}
  def admit_configured(home) when is_binary(home) and home != "" do
    with {:ok, record} <- configured(home), do: admit(record)
  end

  @doc """
  The record a process that booted no engine reads for `home`: the role its
  settings file configures, a device when the home carries the moved marker,
  the marker's own error when it cannot be read. For a tree-less verb
  (`admit_configured/1`, `fermix home status` with Fermix stopped).
  """
  @spec configured(Path.t()) :: {:ok, record()} | {:error, error()}
  def configured(home) when is_binary(home) and home != "" do
    with {:ok, config} <- ConfigStore.engine_config(home) do
      configured_record(configured_role(config), Moved.read(home))
    end
  end

  defp configured_record(:device, marker),
    do: {:ok, %{role: :device, primary: marker_primary(marker)}}

  defp configured_record(:candidate, _marker), do: {:ok, %{role: :candidate, primary: nil}}

  defp configured_record(:primary, :absent), do: {:ok, %{role: :primary, primary: nil}}
  defp configured_record(:primary, {:ok, %{to: to}}), do: {:ok, %{role: :device, primary: to}}
  defp configured_record(:primary, {:error, reason}), do: {:error, reason}

  @doc "The sentence a person is shown for a refusal from `admit/1` or `admit_configured/1`."
  @spec refusal_sentence(refusal() | error()) :: String.t()
  def refusal_sentence({:device_role, sentence}) when is_binary(sentence), do: sentence
  def refusal_sentence(error), do: error_sentence(error)

  @doc """
  Resolves and records the role at boot, before any child starts. A home that
  must not run as the primary raises with `error_sentence/1`, which fails the
  boot with a non-zero exit.
  """
  @spec remember!(Path.t(), keyword() | map() | nil) :: :ok
  def remember!(root, config) when is_binary(root) and root != "" do
    case boot(root, config) do
      {:ok, record} -> :persistent_term.put(@record_key, record)
      {:error, reason} -> raise error_sentence(reason)
    end
  end

  @doc "The record this boot made. Raises in a process whose engine never booted."
  @spec recorded() :: record()
  def recorded do
    case booted() do
      %{} = record ->
        record

      nil ->
        raise "the engine role is recorded when the engine boots, and this process booted none"
    end
  end

  @doc """
  The record this boot made, or `nil` in a process that booted no engine (a
  tree-less CLI verb), which is no engine and so neither role.
  """
  @spec booted() :: record() | nil
  def booted, do: @record_key |> :persistent_term.get(nil) |> as_record()

  # Anything but a well-formed record reads as no record (@doc false so the
  # shape check is pinned without writing the VM-global term).
  @doc false
  @spec as_record(term()) :: record() | nil
  def as_record(%{role: role, primary: primary} = record)
      when role in [:primary, :device, :candidate] and (is_binary(primary) or is_nil(primary)),
      do: record

  def as_record(_absent_or_not_a_record), do: nil

  @doc "The role this boot runs in."
  @spec current() :: role()
  def current, do: recorded().role

  @doc "The one sentence a boot refusal is reported with."
  @spec error_sentence(error()) :: String.t()
  def error_sentence({:home_moved, %{to: to, moved_at: %DateTime{} = at, epoch: epoch}}) do
    "This home moved to #{to} on #{Date.to_iso8601(DateTime.to_date(at))} at epoch " <>
      "#{epoch}; " <> remedy()
  end

  def error_sentence({:invalid_marker, path, _detail}),
    do:
      "The moved marker at #{path} is not one Fermix wrote, so this home cannot start as " <>
        "the primary; " <> remedy()

  def error_sentence({:file, path, reason}),
    do:
      "Fermix could not read #{path} (#{:file.format_error(reason)}), so it cannot tell " <>
        "whether this home moved; fix the file's permissions and start it again."

  def error_sentence({:config, path, reason}),
    do:
      "Fermix could not read the engine role from #{path} (#{config_reason(reason)}), so " <>
        "it cannot tell whether this home is the primary; fix the file and try again."

  defp config_reason(reason) when is_atom(reason), do: :file.format_error(reason)
  defp config_reason(reason) when is_binary(reason), do: String.trim(reason)

  defp remedy,
    do:
      "run it in the device role (#{@section} role = \"device\") or restore a snapshot " <>
        "into an empty home."

  @doc """
  Whether the engine `record` describes may start a turn, call a provider, use
  or refresh a provider token, or write long-term memory: the primary always
  may, a device or a candidate never, refusing by name with the sentence a
  person is shown.
  """
  @spec admit(record()) :: :ok | {:error, refusal()}
  def admit(%{role: :primary}), do: :ok

  def admit(%{role: :candidate}),
    do:
      {:error,
       {:device_role,
        "This engine is a candidate primary waiting for its move; it serves nothing " <>
          "until the move makes it the primary."}}

  def admit(%{role: :device, primary: primary}) when is_binary(primary) or is_nil(primary),
    do:
      {:error,
       {:device_role,
        "This engine runs in the device role; the primary is #{primary || "elsewhere"}."}}

  @doc "Every child a device-role boot leaves out, with the reason it is left out."
  @spec primary_only_reasons() :: [{module(), String.t()}]
  def primary_only_reasons, do: @primary_only

  @doc "The modules of the children a device-role boot leaves out."
  @spec primary_only() :: [module()]
  def primary_only, do: @primary_only_modules

  @doc "Every child only a device-role boot starts, with the reason the primary leaves it out."
  @spec device_only_reasons() :: [{module(), String.t()}]
  def device_only_reasons, do: @device_only

  @doc "The modules of the children only a device-role boot starts."
  @spec device_only() :: [module()]
  def device_only, do: @device_only_modules

  @doc "Every child a candidate boot starts, with why; it starts nothing else."
  @spec candidate_keeps() :: [{module(), String.t()}]
  def candidate_keeps, do: @candidate_keeps

  @doc """
  `children` as `role` starts them: without every device-only child for the
  primary, without every primary-only child for a device, and only the kept
  ones (`candidate_keeps/0`) for a candidate. A child is named by the module
  it starts, in any shape a supervisor accepts; anything else raises.
  """
  @spec children([child()], role()) :: [child()]
  def children(children, :primary) when is_list(children),
    do:
      Enum.reject(
        children,
        &(child_module(&1) in (@device_only_modules ++ @candidate_only_modules))
      )

  def children(children, :device) when is_list(children),
    do:
      Enum.reject(
        children,
        &(child_module(&1) in (@primary_only_modules ++ @candidate_only_modules))
      )

  def children(children, :candidate) when is_list(children),
    do: Enum.filter(children, &(child_module(&1) in @candidate_keep_modules))

  defp child_module(%{start: {module, _function, _args}}) when is_atom(module), do: module
  defp child_module({module, _arg}) when is_atom(module), do: module
  defp child_module(module) when is_atom(module), do: module

  defp child_module(other),
    do: raise(ArgumentError, "not a supervised child: #{inspect(other)}")

  @doc """
  The `[fermix_core.engine]` section in the shape application environment
  holds: `[]` when it says nothing, else the keys it sets:
  `role: :primary | :device | :candidate`. Accepts the parsed file
  (string keys and values), its own output and `to_keyword/1`'s. Raises naming
  the key on any other key or value.
  """
  @spec normalize(keyword() | map() | nil) :: keyword()
  def normalize(nil), do: []

  def normalize(config) when is_map(config) or is_list(config) do
    entries = entries!(config)

    Enum.flat_map(@config_keys, fn key ->
      case List.keyfind(entries, key, 0) do
        nil -> []
        {"role", value} -> [role: role!(value)]
      end
    end)
  end

  @doc "The inverse of `normalize/1`, in the spellings `config.toml` holds."
  @spec to_keyword(keyword() | map() | nil) :: keyword()
  def to_keyword(config) when is_list(config) or is_map(config) or is_nil(config) do
    config
    |> normalize()
    |> Enum.map(fn {:role, role} -> {:role, Atom.to_string(role)} end)
  end

  defp entries!(config) do
    entries = Enum.map(config, &entry!/1)
    unknown = for {key, _value} <- entries, key not in @config_keys, do: key

    if unknown != [] do
      raise ArgumentError,
            "config.toml #{@section} has unknown key(s): #{Enum.join(Enum.sort(unknown), ", ")}. " <>
              "Allowed keys: #{Enum.join(@config_keys, ", ")}. Remove or fix the key(s); " <>
              "the daemon will not boot until this is fixed."
    end

    entries
  end

  defp entry!({key, value}) when is_binary(key) or is_atom(key), do: {to_string(key), value}

  defp entry!(other),
    do: raise(ArgumentError, "config.toml #{@section} is not a table: #{inspect(other)}")

  defp role!(role) when role in [:primary, :device, :candidate], do: role
  defp role!("primary"), do: :primary
  defp role!("device"), do: :device
  defp role!("candidate"), do: :candidate

  defp role!(other) do
    raise ArgumentError,
          ~s(config.toml #{@section} role must be "primary", "device" or "candidate", and ) <>
            "#{inspect(other)} is not. Fix it; the daemon will not boot until this is fixed."
  end
end
