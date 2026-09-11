defmodule FermixCore.Plugins.Auth.TelemetryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Auth.Telemetry, as: AuthTelemetry

  @authorize_url "https://x.com/i/oauth2/authorize?client_id=x-id&state=opaque-state"

  @refused %{
    provider: "x",
    provider_name: "X",
    status: 401,
    error: "unauthorized_client",
    description: "Missing valid authorization header"
  }

  # The handler runs in the emitting process, so filtering on the test's own
  # pid keeps a concurrent emitter's event out of this mailbox.
  setup do
    parent = self()
    handler = "plugin-auth-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        AuthTelemetry.event(),
        fn _event, measurements, metadata, _config ->
          if self() == parent, do: send(parent, {:plugin_auth, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp emitted(op, outcome) do
    :ok = AuthTelemetry.emit(op, "x", outcome, AuthTelemetry.start())
    assert_received {:plugin_auth, measurements, metadata}
    {measurements, metadata}
  end

  # `fermix_opik` cannot depend on fermix_core, so its aggregation test mirrors
  # this list by hand; pinning it here means a new op fails until both agree.
  test "the event and its op vocabulary are pinned" do
    assert AuthTelemetry.event() == [:fermix, :plugin, :auth]
    assert AuthTelemetry.ops() == [:login, :refresh, :logout, :set, :clear]
  end

  test "is registered for the trace stream as a plugin_auth row keyed on the plugin" do
    assert AuthTelemetry.trace_event_definitions() == [
             %{
               event: [:fermix, :plugin, :auth],
               trace_type: :agent_event,
               agent_field: :plugin,
               trace_event: "plugin_auth"
             }
           ]
  end

  test "a success carries its tag and its duration, nothing else" do
    {measurements, metadata} = emitted(:login, {:ok, :ready})

    assert %{duration_ms: duration} = measurements
    assert is_integer(duration) and duration >= 0
    assert metadata == %{op: :login, plugin: "x", result: :ready}

    {_measurements, logout} = emitted(:logout, {:ok, :logged_out})
    assert logout.result == :logged_out
  end

  test "a refused sign-in client carries its class and the vendor's own words" do
    {_measurements, metadata} = emitted(:refresh, {:error, {:oauth_client_rejected, @refused}})

    assert metadata == %{
             op: :refresh,
             plugin: "x",
             result: :error,
             error_class: :oauth_client_rejected,
             vendor_error: "unauthorized_client",
             vendor_description: "Missing valid authorization header"
           }
  end

  # The raw reason never rides: it can carry the authorize url, which must never
  # reach a log or a trace, and a vendor body can carry anything at all.
  test "any other failure carries a bounded class and never the reason" do
    cases = [
      {:needs_client_config, :needs_client_config},
      {{:port_in_use, 1459}, :port_in_use},
      {{:opener_failed, :browser_missing, @authorize_url}, :opener_failed},
      {"Token exchange failed (400): %{\"error\" => \"invalid_grant\"}", :unclassified},
      {%RuntimeError{message: @authorize_url}, :unclassified},
      {{"not an atom", @authorize_url}, :unclassified},
      {nil, :unclassified}
    ]

    for {reason, class} <- cases do
      {_measurements, metadata} = emitted(:login, {:error, reason})

      assert metadata == %{op: :login, plugin: "x", result: :error, error_class: class},
             "#{inspect(reason)} emitted #{inspect(metadata)}"

      refute inspect(metadata) =~ "https://"
      refute inspect(metadata) =~ "invalid_grant"
    end
  end

  test "an op outside the vocabulary is refused, not emitted" do
    assert_raise FunctionClauseError, fn ->
      AuthTelemetry.emit(:frobnicate, "x", {:ok, :ready}, AuthTelemetry.start())
    end

    refute_received {:plugin_auth, _measurements, _metadata}
  end
end
