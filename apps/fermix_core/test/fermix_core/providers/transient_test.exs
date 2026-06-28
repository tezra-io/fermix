defmodule FermixCore.Providers.TransientTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.Transient

  @finch_pool_error %RuntimeError{
    message:
      "Finch was unable to provide a connection within the timeout due to excess queuing for connections"
  }

  describe "retryable?/1" do
    test "true for transient transport kinds" do
      for kind <- [:connection_unavailable, :timeout, :transport_closed, :network] do
        assert Transient.retryable?({:provider_transport_error, %{kind: kind}}), "kind #{kind}"
      end
    end

    test "true for transient api kinds (5xx / overload)" do
      for kind <- [:timeout, :provider_unavailable] do
        assert Transient.retryable?({:provider_error, %{kind: kind}}), "kind #{kind}"
      end
    end

    test "true for the bare Finch pool-checkout RuntimeError" do
      assert Transient.retryable?(@finch_pool_error)
    end

    test "false for rate_limit and quota (need Retry-After, not retried here)" do
      refute Transient.retryable?({:provider_error, %{kind: :rate_limit}})
      refute Transient.retryable?({:provider_error, %{kind: :quota}})
    end

    test "false for deterministic / unknown failures" do
      refute Transient.retryable?({:provider_error, %{kind: :auth}})
      refute Transient.retryable?({:provider_error, %{kind: :provider}})
      refute Transient.retryable?({:provider_transport_error, %{kind: :transport}})
      refute Transient.retryable?(%RuntimeError{message: "some other genuine bug"})
      refute Transient.retryable?(:weird)
    end
  end

  describe "connection_unavailable?/1" do
    test "true only for the network-wide pool-checkout failure" do
      assert Transient.connection_unavailable?(
               {:provider_transport_error, %{kind: :connection_unavailable}}
             )

      assert Transient.connection_unavailable?(@finch_pool_error)
    end

    test "false for other transient kinds and unrelated errors" do
      refute Transient.connection_unavailable?({:provider_transport_error, %{kind: :timeout}})
      refute Transient.connection_unavailable?({:provider_error, %{kind: :rate_limit}})
      refute Transient.connection_unavailable?(%RuntimeError{message: "other bug"})
      refute Transient.connection_unavailable?(:weird)
    end
  end
end
