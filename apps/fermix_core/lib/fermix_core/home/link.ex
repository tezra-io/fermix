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
  its primary (`nil` on any other role, or a device role with no desktop link).
  `desktops` are the primary's desktop peers. `enrollment` is the primary's
  enrollment window, `state` `:open`, `:used` or `:expired` and when it
  expires, `nil` when none was opened since the engine started.
  """
  @type status :: %{
          primary: map() | nil,
          desktops: [map()],
          enrollment: %{state: :open | :used | :expired, expires_at: DateTime.t()} | nil
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
  Primary role: opens the enrollment window (spec §7.1) and answers the code and
  when it expires. One window at a time; opening another replaces it. A
  refusal carries the sentence a person is shown.
  """
  @callback open_enrollment() ::
              {:ok, %{code: String.t(), expires_at: DateTime.t()}}
              | {:error, {:unavailable, String.t()}}

  @doc "The configured implementation; raises when none is configured."
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:fermix_core, :home_link)
end
