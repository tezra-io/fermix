defmodule FermixCore.Home.Link do
  @moduledoc """
  The rail-side half of the home (M75), as `fermix_core` sees it: forwarding a
  Fermix-wide management call from a desktop's device-role engine to its
  primary, the rail's facts for `home.status`, opening an enrollment window
  on a primary, naming a desktop's primary anew after a replace of the
  server, and receiving the home back on a desktop (Always On's move back).

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
  `:expired`, when it expires, its `kind` (`:manual`, the code a person
  copies, or `:provisioned`, the code inside a server Fermix created), the
  `candidate_id` that enrolled through it (nil until one did) and `awake_ms`,
  how long this engine has held it while the computer was awake; `nil` when
  no window is kept. Both counts are on the monotonic clock, which stops
  while the computer sleeps (`home.status.summary`, M75 lean v1 §7).
  """
  @type status :: %{
          primary: map() | nil,
          desktops: [map()],
          enrollment:
            %{
              state: :open | :used | :expired,
              expires_at: DateTime.t(),
              kind: :manual | :provisioned,
              candidate_id: String.t() | nil,
              awake_ms: non_neg_integer()
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
  Primary role: opens the enrollment window (spec §7.1) of `kind` and answers
  the code and when it expires: `:manual` (`home.enroll.open`, thirty
  minutes) or `:provisioned` (the code inside a server Fermix creates, 24
  hours, M75 lean v1 L15). One window at a time; opening another replaces it,
  except that a manual one is refused while a provisioned one is open, and
  while a used one's candidate is still held. A refusal carries the sentence
  a person is shown.
  """
  @callback open_enrollment(:manual | :provisioned) ::
              {:ok, %{code: String.t(), expires_at: DateTime.t()}}
              | {:error, {:unavailable, String.t()}}

  @doc """
  Primary role: releases the enrollment window when it is of `kind`: the
  provisioned one when the server it was opened for was never created or is
  being deleted (a used one then no longer holds a manual code back), the
  manual one when the owner cancels its code (Always On's Cancel the code).
  An open one ends now. A window of the other kind, or none, and any other
  role, is left as it is.
  """
  @callback withdraw_enrollment(:manual | :provisioned) ::
              :ok | {:error, {:unavailable, String.t()}}

  @doc """
  Device role: the server this desktop reaches is known by `name` from now on
  (the new server of a replace, once the move to it is done; it is reached at
  the same node id). The desktop link keeps it and every sentence names it.
  `{:error, reason}` when no link runs or the name could not be kept.
  """
  @callback rename_primary(String.t()) :: :ok | {:error, term()}

  @doc """
  Any role: removes the desktop row whose Noise key is `noise_pk` from the
  device list of the home at `root` (a staged home, never the running one's):
  a return stages the server's home on the computer it left, whose own row
  that list holds. A list with no such row, or no list, has nothing to drop;
  a row of that key that is no desktop is refused by name.
  """
  @callback drop_desktop_row(Path.t(), <<_::256>>) :: :ok | {:error, term()}

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
