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
end
