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

  describe "stale?/1" do
    test "nil expiry is never stale" do
      refute TokenExpiry.stale?(nil)
    end

    test "a future expiry is not stale" do
      refute TokenExpiry.stale?(DateTime.add(DateTime.utc_now(), 3600, :second))
    end

    test "minutes past expiry is not stale (idle but healthy — refreshes on use)" do
      refute TokenExpiry.stale?(DateTime.add(DateTime.utc_now(), -60, :second))
    end

    test "well past expiry is stale (dormant, default grace)" do
      assert TokenExpiry.stale?(DateTime.add(DateTime.utc_now(), -7200, :second))
    end

    test "raises on a non-DateTime expiry" do
      assert_raise ArgumentError, fn -> TokenExpiry.stale?(:nope) end
    end
  end

  describe "stale?/2" do
    test "the grace window is configurable" do
      past = DateTime.add(DateTime.utc_now(), -120, :second)
      refute TokenExpiry.stale?(past, 300_000)
      assert TokenExpiry.stale?(past, 60_000)
    end
  end
end
