defmodule FermixCore.Auth.TokenExpiry do
  @moduledoc false

  @refresh_skew_ms 10_000

  @spec refresh_due?(DateTime.t() | nil) :: boolean()
  def refresh_due?(nil), do: false

  def refresh_due?(%DateTime{} = expires_at) do
    DateTime.diff(expires_at, DateTime.utc_now(), :millisecond) <= @refresh_skew_ms
  end

  def refresh_due?(expires_at) do
    raise ArgumentError, "expires_at must be a DateTime or nil, got: #{inspect(expires_at)}"
  end

  # A token is "stale" once now is past `expires_at` by more than this grace.
  # `expires_at` is the ACCESS token's expiry, which a healthy provider refreshes
  # lazily on use (within @refresh_skew_ms). Being seconds-to-minutes past expiry
  # is therefore normal for an idle-but-healthy provider; only being WELL past it
  # signals a dormant provider whose refresh may have lapsed and likely needs
  # re-auth. Deliberately far beyond the refresh skew to avoid false alarms on
  # providers that simply have not been called recently.
  @stale_after_ms 3_600_000

  @spec stale?(DateTime.t() | nil) :: boolean()
  def stale?(expires_at), do: stale?(expires_at, @stale_after_ms)

  @spec stale?(DateTime.t() | nil, non_neg_integer()) :: boolean()
  def stale?(nil, grace_ms) when is_integer(grace_ms) and grace_ms >= 0, do: false

  def stale?(%DateTime{} = expires_at, grace_ms) when is_integer(grace_ms) and grace_ms >= 0 do
    DateTime.diff(DateTime.utc_now(), expires_at, :millisecond) > grace_ms
  end

  def stale?(expires_at, _grace_ms) do
    raise ArgumentError, "expires_at must be a DateTime or nil, got: #{inspect(expires_at)}"
  end
end
