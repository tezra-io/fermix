defmodule FermixCore.Home.Link do
  @moduledoc """
  The rail-side half of the home (M75), as `fermix_core` sees it: forwarding a
  Fermix-wide management call from a desktop's device-role engine to its
  primary, the rail's facts for `home.status`, opening an enrollment window
  on a primary, and receiving the home back on a desktop (Always On's move
  back).

  `fermix_core` must never compile-depend on `fermix_channels`, so the
  implementation is injected **by module** through
  `config :fermix_core, :home_link`, the same app-env module injection the jobs
  delivery path (`[:fermix_core, :jobs, :delivery_channels]`) and the harness
  continuation dispatcher use. The implementation is
  `FermixChannels.Home.Link`. An unconfigured key is a configuration error and
  raises at the call.

  `forwarding/0` is the one answer to how this engine reaches its primary
  (Always On setup §7): on a linked desktop, the rail's `forward/2` as
  `:primary_forward`, the option the management router composes a request
  with; on any other engine, nothing. The daemon's dispatch, the Always On
  watch and the setup page all read it, so each draws the same summary.
  """

  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Role
  alias FermixCore.Management.Protocol
  alias FermixCore.Setup.ConfigStore

  @typedoc """
  What the rail knows for `home.status`. `primary` is the device role's link to
  its primary (`nil` on any other role, or a device role with no desktop link),
  with `down_ms`, how long it has had no session while this computer was
  awake, and `down_at`, when that stretch began on the wall clock (both nil
  while one is up). `desktops` are the primary's desktop peers.
  `enrollment` is the primary's enrollment window: `state` `:open`, `:used` or
  `:expired`, a computer's join's `:awaiting_approval`, `:approved` or
  `:denied` (M97 §3.1), its `purpose`, when it expires, the `candidate_id`
  that enrolled through it (nil until one did), the `joiner` waiting for the
  owner (`name` and `platform`, never its digits, or nil) and the computer that joined
  through it (`joined`, its `device_id` and `name`, nil until one did);
  `nil` when no window is kept. `down_ms` is on the
  monotonic clock, which stops while the computer sleeps
  (`home.status.summary`, M75 lean v1 §7).
  """
  @type status :: %{
          primary: map() | nil,
          desktops: [map()],
          enrollment:
            %{
              required(:state) =>
                :open | :used | :expired | :awaiting_approval | :approved | :denied,
              required(:expires_at) => DateTime.t(),
              required(:candidate_id) => String.t() | nil,
              optional(:purpose) => :candidate | :computer,
              optional(:joiner) => map() | nil,
              optional(:joined) => map() | nil
            }
            | nil
        }

  @doc """
  Device role: sends one management request to the primary over the rail and
  answers what the primary answered, or the management error
  `primary_unreachable` with its sentence while the link is down or the
  primary did not answer in time. `opts`: `:deadline_ms`, how long the answer
  may take (the link's own deadline, under the apps' call timeouts, unless
  said).
  """
  @callback forward(Protocol.request(), keyword()) :: Protocol.route_result()

  @doc "The rail's facts for `home.status`."
  @callback status() :: status()

  @doc """
  Primary role: opens the enrollment window (spec §7.1, `home.enroll.open`,
  thirty minutes) and answers the code and when it expires. One window at a
  time; opening another replaces it. `returning` is the device id of the
  linked desktop the window is opened for, to take the home back (Always
  On's move back), else nil: the window keeps it, and so does the candidate
  that enrolls through it. A refusal carries the sentence a person is shown.
  """
  @callback open_enrollment(String.t() | nil) ::
              {:ok, %{code: String.t(), expires_at: DateTime.t()}}
              | {:error, {:unavailable, String.t()}}

  @doc """
  Primary role: releases the enrollment window when the owner cancels its
  code (Always On's Cancel). An open one ends now. None, and any other role,
  is left as it is.
  """
  @callback withdraw_enrollment() ::
              :ok | {:error, {:unavailable, String.t()}}

  @doc """
  Primary role: opens the enrollment window for a computer that joins the
  home (M97 §3.1, Add a computer), thirty minutes, and answers its code and
  when it expires. Refused by name while a window of the other purpose is
  open. A refusal carries the sentence a person is shown.
  """
  @callback open_join() ::
              {:ok, %{code: String.t(), expires_at: DateTime.t()}}
              | {:error, {:unavailable, String.t()}}

  @doc """
  Primary role: the owner approves the computer waiting on the window with
  the six digits `sas` it shows: its row is written and it is told. Digits
  that are not its own deny it and spend the code (`:sas_mismatch`); no
  computer waiting is `:none`.
  """
  @callback approve_join(String.t()) ::
              {:ok, %{device_id: String.t(), name: String.t()}}
              | {:error, :none | :sas_mismatch | {:unavailable, String.t()}}

  @doc "Primary role: the owner denies the computer waiting on the window; none is nothing."
  @callback deny_join() :: :ok | {:error, {:unavailable, String.t()}}

  @doc """
  Primary role: drops the held candidate `candidate_id` the owner forgot
  (Always On's Forget this server). One no longer held is forgotten already.
  A refusal carries the sentence a person is shown.
  """
  @callback forget_candidate(String.t()) :: :ok | {:error, {:unavailable, String.t()}}

  @doc """
  Any role: removes the desktop row whose Noise key is `noise_pk` from the
  device list of the home at `root` (a staged home, never the running one's):
  a return stages the server's home on the computer it left, whose own row
  that list holds. A list with no such row, or no list, has nothing to drop;
  a row of that key that is no desktop is refused by name.
  """
  @callback drop_desktop_row(Path.t(), <<_::256>>) :: :ok | {:error, term()}

  @doc """
  Any role: the desktop rows in the device list of the home at `root`, read
  from its file rather than the running store, which starts after
  `fermix_core` and only on the primary: whether a home is an Always On
  server's (`FermixCore.Home.ServerPrimary`). No list holds none.
  """
  @callback home_desktops(Path.t()) ::
              {:ok, [%{device_id: String.t(), name: String.t()}]} | {:error, term()}

  @doc """
  Device role: starts receiving the home back from the server (Always On's
  move back) beside the relay: the candidate subtree under the running device
  tree, for the candidate `FermixCore.Home.Candidate.prepare_return/3` wrote
  under `home`. `:ok` once it runs, as it may already; `{:error,
  :no_device_tree}` on an engine that runs no device tree, `{:error,
  reason}` when it could not start.
  """
  @callback start_return(Path.t()) :: :ok | {:error, term()}

  @doc """
  Device role: stops receiving the home back (Cancel): the candidate subtree
  ends, and with it what kept the computer awake for it. One that is not
  running is nothing to stop.
  """
  @callback stop_return() :: :ok

  @typedoc """
  One computer's device row as the primary holds it (M97 §3.2): its id, the
  name the owner calls it, its system (`"macos"`, `"linux"`, or nil before
  it said), when it last said `hello`, whether it keeps the home's backup
  copies (nil: yes), and whether its session is up and since when.
  """
  @type computer_row :: %{
          device_id: String.t(),
          name: String.t(),
          platform: String.t() | nil,
          last_seen: DateTime.t() | nil,
          backups: boolean() | nil,
          connected: boolean(),
          since: DateTime.t() | nil
        }

  @doc """
  Primary role: every computer's device row (M97 §3.2), with whether its
  session is up. None on any other engine, which holds no device store.
  """
  @callback computer_rows() :: {:ok, [computer_row()]} | {:error, term()}

  @doc """
  Primary role: names the computer `device_id` `name` on its device row
  (`computers.rename`). The name is checked by the caller
  (`FermixCore.Computers.rename/3`); one another computer holds, compared
  without case, is refused here as well, where the rows are written
  (`{:name_taken, name}`), and a computer the home does not hold is
  `{:not_found, device_id}`.
  """
  @callback rename_computer(String.t(), String.t()) ::
              {:ok, computer_row()} | {:error, {:name_taken | :not_found, String.t()} | term()}

  @typedoc "How a request reaches the primary: the rail's `forward/2` on a linked desktop."
  @type forwarding ::
          [primary_forward: (Protocol.request(), keyword() -> Protocol.route_result())] | []

  @doc """
  How this engine reaches its primary, decided from the role it booted in and
  its desktop link (`DesktopLink.linked?/2`): `[primary_forward: forward]` on a
  linked desktop, `[]` otherwise. Read once at a reader's start, as the boot's
  role is, so no request takes both paths in one boot.
  """
  @spec forwarding() :: forwarding()
  def forwarding, do: forwarding(Role.recorded(), ConfigStore.fermix_home())

  @doc "`forwarding/0` for an engine booted as `record` serving `home`."
  @spec forwarding(Role.record(), Path.t()) :: forwarding()
  def forwarding(record, home) when is_map(record) and is_binary(home) do
    if DesktopLink.linked?(record, home),
      do: [primary_forward: Function.capture(impl(), :forward, 2)],
      else: []
  end

  @doc "The configured implementation; raises when none is configured."
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:fermix_core, :home_link)
end
