defmodule FermixCore.Browser.Handoff.Link do
  @moduledoc """
  The rail-side half of a browser hand-off (M75 D18), as `fermix_core` sees
  it: a desktop in the device role sends the cookies it collected to its
  primary and waits for the primary to store them, and sends a wipe.

  `fermix_core` must never compile-depend on `fermix_channels`, so the
  implementation is injected **by module** through
  `config :fermix_core, :browser_handoff_link`, as `FermixCore.Home.Link` is.
  The implementation is `FermixChannels.Desktop.HandoffLink`. An unconfigured
  key is a configuration error and raises at the call.
  """

  @typedoc "One hand-off as the desktop sends it: the cookies are the encoded payload."
  @type handoff :: %{
          handoff_id: String.t(),
          sites: [String.t()],
          expires_at: DateTime.t(),
          count: pos_integer(),
          payload: binary()
        }

  @typedoc """
  Why a hand-off or a wipe did not reach the primary: unreachable (with the
  sentence naming it), refused by the primary (with its sentence), or not
  answered in time.
  """
  @type failure ::
          {:primary_unreachable, String.t()}
          | {:primary_refused, String.t()}
          | :primary_timeout

  @doc """
  Sends `handoff` to the primary and answers how many cookies it stored and
  until when.
  """
  @callback send_handoff(handoff()) ::
              {:ok, %{cookies: non_neg_integer(), expires_at: DateTime.t()}}
              | {:error, failure()}

  @doc """
  Asks the primary to wipe the hand-offs of `sites`, or every one (`nil`), and
  answers how many cookies it deleted.
  """
  @callback send_wipe([String.t()] | nil) ::
              {:ok, %{cookies: non_neg_integer()}} | {:error, failure()}

  @doc "The configured implementation; raises when none is configured."
  @spec impl() :: module()
  def impl, do: Application.fetch_env!(:fermix_core, :browser_handoff_link)
end
