defmodule FermixCore.Home.Link do
  @moduledoc """
  The rail-side half of the home (M75), as `fermix_core` sees it: forwarding a
  Fermix-wide management call from a desktop's device-role engine to its
  primary, the rail's facts for `home.status`, and opening an enrollment window
  on a primary.

  `fermix_core` must never compile-depend on `fermix_channels`, so the
  implementation is injected **by module** through
  `config :fermix_core, :home_link`, the same app-env module injection the jobs
  delivery path (`[:fermix_core, :jobs, :delivery_channels]`) and the harness
  continuation dispatcher use. The implementation is
  `FermixChannels.Home.Link`. An unconfigured key is a configuration error and
  raises at the call.
  """

  alias FermixCore.Management.Protocol

  @typedoc """
  What the rail knows for `home.status`. `primary` is the device role's link to
  its primary (`nil` on any other role, or a device role with no desktop link),
  with `down_ms`, how long it has had no session while this computer was
  awake (nil while one is up). `desktops` are the primary's desktop peers.
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
  Releases the primary's provisioned window (the server it was opened for
  was never created, or is being deleted): an open one ends, a used one no
  longer holds a manual code back. A manual window, or none, and any other
  role, is left as it is.
  """
  @callback withdraw_enrollment() :: :ok | {:error, {:unavailable, String.t()}}

  @doc "The configured implementation; raises when none is configured."
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:fermix_core, :home_link)
end
