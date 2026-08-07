defmodule FermixCore.Delivery.ErrorTest do
  @moduledoc """
  The closed channel-delivery error vocabulary
  (MILESTONE_30_TEMPORAL_EVENTS_AND_PROACTIVE_REMINDERS §11.3/§11.4).

  Every assertion here is pure: no channel, no socket, no host state.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Delivery.Error

  @permanent_kinds [
    :authentication,
    :authorization,
    :invalid_destination,
    :malformed_request,
    :remote_rejected,
    :adapter_unavailable
  ]

  @transport_kinds [
    :pool_unavailable,
    :closed,
    :connection_refused,
    :connection_reset,
    :network_unreachable,
    :timeout
  ]

  # The exact RuntimeError message Finch reraises on a pool-checkout queue
  # timeout; `HttpClient.connection_unavailable?/1` is the sanctioned predicate.
  @pool_checkout_message "Finch was unable to provide a connection within the timeout " <>
                           "due to excess queuing for connections"

  describe "normalize/1 — success and pass-through" do
    test "a successful send stays :ok" do
      assert :ok = Error.normalize(:ok)
    end

    test "adapter-owned structured reasons pass through untouched" do
      reasons =
        [
          {:rate_limited, 0},
          {:rate_limited, 2_000},
          {:http_status, 400},
          {:http_status, 503},
          {:unsupported_delivery_platform, "cli"},
          {:invalid_delivery_adapter, FermixCore.Delivery.ErrorTest.NoSuchAdapter}
        ] ++
          Enum.map(@permanent_kinds, &{:permanent, &1}) ++
          Enum.map(@transport_kinds, &{:transport, &1})

      for reason <- reasons do
        assert {:error, ^reason} = Error.normalize({:error, reason}),
               "expected #{inspect(reason)} to pass through the normalizer unchanged"
      end
    end
  end

  describe "normalize/1 — watchdog results" do
    test "the watchdog expiry becomes :delivery_timeout" do
      assert {:error, :delivery_timeout} = Error.normalize({:error, :delivery_timeout})
    end

    test "every raw crash reason collapses to the fixed worker_crash reason" do
      raw_reasons = [
        :killed,
        {:shutdown, :boom},
        %RuntimeError{message: "bot token xoxb-leaked"},
        {%ArgumentError{message: "argument error"}, [{:erlang, :hd, [[]], []}]}
      ]

      for raw <- raw_reasons do
        assert {:error, {:delivery_crashed, :worker_crash}} =
                 Error.normalize({:error, {:delivery_crashed, raw}}),
               "expected #{inspect(raw)} to be reduced to :worker_crash"
      end
    end

    test "a crash reason never leaks its raw payload into the reason" do
      assert {:error, reason} =
               Error.normalize(
                 {:error, {:delivery_crashed, %RuntimeError{message: "xoxb-secret"}}}
               )

      refute inspect(reason) =~ "xoxb-secret"
    end
  end

  describe "normalize/1 — transport mapping" do
    test "Req transport errors map centrally to the closed transport sub-reasons" do
      mappings = [
        {:closed, :closed},
        {:econnrefused, :connection_refused},
        {:econnreset, :connection_reset},
        {:ehostunreach, :network_unreachable},
        {:enetunreach, :network_unreachable},
        {:nxdomain, :network_unreachable},
        {:timeout, :timeout}
      ]

      for {raw, expected} <- mappings do
        assert {:error, {:transport, ^expected}} =
                 Error.normalize({:error, %Req.TransportError{reason: raw}}),
               "expected transport #{inspect(raw)} to map to #{inspect(expected)}"
      end
    end

    test "the Finch pool-checkout RuntimeError maps to :pool_unavailable" do
      exception = %RuntimeError{message: @pool_checkout_message}

      assert {:error, {:transport, :pool_unavailable}} = Error.normalize({:error, exception})
    end

    test "an unlisted transport reason is a contract violation, not a guessed sub-reason" do
      assert capture_log(fn ->
               assert {:error, {:unexpected_delivery_result, :invalid_contract}} =
                        Error.normalize({:error, %Req.TransportError{reason: :ehostdown}})
             end) =~ "ehostdown"
    end
  end

  describe "normalize/1 — contract violations" do
    test "free-form adapter strings are terminal invalid_contract and are logged" do
      log =
        capture_log(fn ->
          assert {:error, {:unexpected_delivery_result, :invalid_contract}} =
                   Error.normalize({:error, "Slack API error: 429"})
        end)

      assert log =~ "Slack API error: 429"
    end

    test "unclassified atoms, bare results, and non-tuples are invalid_contract" do
      raw_results = [
        {:error, :not_configured},
        {:error, %RuntimeError{message: "some other bug"}},
        {:ok, "sent"},
        :sent,
        nil
      ]

      for raw <- raw_results do
        assert capture_log(fn ->
                 assert {:error, {:unexpected_delivery_result, :invalid_contract}} =
                          Error.normalize(raw),
                        "expected #{inspect(raw)} to be an invalid contract"
               end) =~ "delivery"
      end
    end

    test "an adapter that already classified its own violation is not re-reported as one" do
      # An adapter whose runner contract is open (Signal's CLI) closes it
      # itself and returns the in-vocabulary reason. Logging that as "outside
      # the closed error vocabulary" would make the trace say the opposite of
      # what happened.
      log =
        capture_log(fn ->
          assert {:error, {:unexpected_delivery_result, :invalid_contract}} =
                   Error.normalize({:error, {:unexpected_delivery_result, :invalid_contract}})
        end)

      refute log =~ "outside the closed error vocabulary"
    end

    test "a rate-limit hint with a nonsense delay is not accepted as vocabulary" do
      assert capture_log(fn ->
               assert {:error, {:unexpected_delivery_result, :invalid_contract}} =
                        Error.normalize({:error, {:rate_limited, -1}})
             end) =~ "rate_limited"
    end

    test "the logged raw shape is bounded so a huge body cannot flood the log" do
      log =
        capture_log(fn ->
          assert {:error, {:unexpected_delivery_result, :invalid_contract}} =
                   Error.normalize({:error, String.duplicate("x", 5_000)})
        end)

      refute log =~ String.duplicate("x", 600)
    end
  end

  describe "retryable?/1" do
    test "the positive allowlist is exactly §11.4" do
      retryable =
        Enum.map(@transport_kinds, &{:transport, &1}) ++
          [
            :delivery_timeout,
            {:rate_limited, 1_000},
            {:http_status, 408},
            {:http_status, 425},
            {:http_status, 429},
            {:http_status, 500},
            {:http_status, 503},
            {:http_status, 599}
          ]

      for reason <- retryable do
        assert Error.retryable?(reason), "expected #{inspect(reason)} to be retryable"
      end
    end

    test "everything else — including a worker crash — is terminal" do
      terminal =
        Enum.map(@permanent_kinds, &{:permanent, &1}) ++
          [
            {:http_status, 400},
            {:http_status, 401},
            {:http_status, 403},
            {:http_status, 404},
            {:http_status, 409},
            {:http_status, 499},
            {:unsupported_delivery_platform, "cli"},
            {:invalid_delivery_adapter, FermixCore.Delivery.ErrorTest.NoSuchAdapter},
            {:delivery_crashed, :worker_crash},
            {:unexpected_delivery_result, :invalid_contract}
          ]

      for reason <- terminal do
        refute Error.retryable?(reason), "expected #{inspect(reason)} to be terminal"
      end
    end
  end

  describe "retry_after_hint/1" do
    test "extracts the server-provided rate-limit delay" do
      assert {:ok, 2_000} = Error.retry_after_hint({:rate_limited, 2_000})
      assert {:ok, 0} = Error.retry_after_hint({:rate_limited, 0})
    end

    test "no other reason carries a delay hint" do
      for reason <- [
            :delivery_timeout,
            {:transport, :closed},
            {:http_status, 429},
            {:permanent, :authentication},
            {:delivery_crashed, :worker_crash},
            {:unexpected_delivery_result, :invalid_contract}
          ] do
        assert :error = Error.retry_after_hint(reason),
               "expected #{inspect(reason)} to carry no retry-after hint"
      end
    end
  end
end
