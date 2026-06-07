defmodule FermixCore.Auth.TokenExpiryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.TokenExpiry

  test "nil expiry is fresh" do
    refute TokenExpiry.refresh_due?(nil)
  end

  test "fresh tokens outside the fixed refresh window are reused" do
    refute TokenExpiry.refresh_due?(DateTime.add(DateTime.utc_now(), 60, :second))
  end

  test "tokens inside the fixed refresh window are due" do
    assert TokenExpiry.refresh_due?(DateTime.add(DateTime.utc_now(), 9, :second))
  end

  test "expired tokens are due" do
    assert TokenExpiry.refresh_due?(DateTime.add(DateTime.utc_now(), -1, :second))
  end
end
