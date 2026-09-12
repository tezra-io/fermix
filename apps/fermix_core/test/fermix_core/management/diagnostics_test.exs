defmodule FermixCore.Management.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Diagnostics
  alias FermixCore.Management.Doctor.Descriptor
  alias FermixCore.Management.Protocol

  @identity %{
    "engine_id" => "fermix-engine-test",
    "product_version" => "1.2.3",
    "build_id" => "build-456",
    "source_commit" => "abcdef123456",
    "distribution_identity" => "macos_app",
    "artifact_target" => "macos_aarch64",
    "architecture" => "arm64",
    "pid" => "4321"
  }

  # One fixture per secret class §6 excludes. Each rides in through the only two
  # free-text channels a core diagnostic object has: Doctor summaries and log
  # messages. `absent` is the literal that must never survive.
  @secret_fixtures [
    {"absolute user path", "workspace at /Users/rae/.fermix/memory.db is writable",
     "/Users/rae/.fermix"},
    {"tokenized setup url", "opened http://127.0.0.1:4030/setup?t=SUPERSECRETLAUNCHTOKEN123",
     "SUPERSECRETLAUNCHTOKEN123"},
    {"oauth token", "refresh sent access_token=ya29.a0AfH6SMBnotarealoauthtokenvalue",
     "ya29.a0AfH6SMBnotarealoauthtokenvalue"},
    {"api key", "provider rejected sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
     "sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"},
    {"config api key value", "config has api_key = \"grok-live-9f8e7d6c5b4a1122\"",
     "grok-live-9f8e7d6c5b4a1122"},
    {"authorization header", "sent authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
     "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"},
    {"keyring reference", "read Claude Code-credentials-1a2b3c4d from the keychain",
     "Claude Code-credentials-1a2b3c4d"},
    {"environment value", "env TELEGRAM_BOT_TOKEN=123456789:AAE0not0a0real0telegram0token0x",
     "123456789:AAE0not0a0real0telegram0token0x"},
    # A credential is written in whatever shape the line that logged it used. A
    # pattern that only accepts `key=value` misses the JSON body a provider
    # error quotes and the Elixir `inspect/1` of a header list, which is exactly
    # how a refresh token reaches `fermix.log` today.
    {"json body oauth token",
     ~s({"error":"invalid_grant","access_token":"ya29.a0AfH6SMjsonshapedtoken"}),
     "ya29.a0AfH6SMjsonshapedtoken"},
    {"inspected refresh token",
     ~s(provider error: %{"refresh_token" => "1//0gLONGREFRESHVALUEabc"}),
     "1//0gLONGREFRESHVALUEabc"},
    {"non-bearer authorization header",
     ~s(headers: [{"authorization", "Basic ZnJlZDpzZWNyZXRwYXNz"}]), "ZnJlZDpzZWNyZXRwYXNz"},
    {"tuple api key header", ~s(headers: [{"x-api-key", "fc-9f8e7d6c5b4a11223344"}]),
     "fc-9f8e7d6c5b4a11223344"}
  ]

  test "builds only the allowlisted core diagnostic object" do
    assert {:ok, report} = Diagnostics.build(opts())

    assert Map.keys(report) |> Enum.sort() ==
             ~w(doctor engine generated_at logs protocol schema_version service)

    assert report["schema_version"] == Diagnostics.schema_version()
    assert report["engine"] == @identity
    {minimum, maximum} = Protocol.supported_version_range()

    assert report["protocol"] == %{
             "current_version" => Protocol.protocol_version(),
             "minimum_version" => minimum,
             "maximum_version" => maximum
           }

    assert report["service"] == %{"scope" => "user", "state" => "installed"}

    assert {:ok, _dt, 0} = DateTime.from_iso8601(report["generated_at"])
  end

  test "carries the latest typed Doctor results and bounded log entries" do
    assert {:ok, report} = Diagnostics.build(opts())

    assert report["doctor"]["session_id"] == "doctor:abc"
    assert report["doctor"]["status"] == "completed"
    assert [check] = report["doctor"]["checks"]
    assert check["id"] == "readiness"

    assert report["logs"]["count"] == 1
    assert report["logs"]["truncated"] == false
    assert [entry] = report["logs"]["entries"]
    assert entry["level"] == "info"
  end

  test "requests at most 500 log entries" do
    parent = self()

    logs_provider = fn params ->
      send(parent, {:logs_params, params})
      {:ok, %{"entries" => [], "count" => 0, "truncated" => false, "cursor" => nil}}
    end

    assert {:ok, _report} = Diagnostics.build(opts(logs_provider: logs_provider))
    assert_receive {:logs_params, params}
    assert params["limit"] == Diagnostics.max_log_entries()
    assert Diagnostics.max_log_entries() == 500
  end

  test "an unavailable Doctor history is reported as absent, never as a failure" do
    assert {:ok, report} = Diagnostics.build(opts(doctor_provider: fn -> {:error, :none} end))
    assert report["doctor"] == nil
  end

  test "a failing source fails the build loudly" do
    assert {:error, :unavailable} =
             Diagnostics.build(opts(identity_provider: fn -> {:error, :no_identity} end))

    assert {:error, :unavailable} =
             Diagnostics.build(opts(logs_provider: fn _params -> {:error, :cursor_expired} end))
  end

  for {label, fixture, absent} <- @secret_fixtures do
    test "excludes #{label} carried in a Doctor summary" do
      doctor_provider = fn ->
        {:ok, doctor_view(unquote(fixture))}
      end

      assert {:ok, report} = Diagnostics.build(opts(doctor_provider: doctor_provider))
      encoded = Jason.encode!(report)

      refute encoded =~ unquote(absent)
      assert encoded =~ "REDACTED"
    end

    test "excludes #{label} carried in a log entry" do
      logs_provider = fn _params ->
        {:ok,
         %{
           "entries" => [
             %{
               "time" => "2026-08-19T10:00:00.000000",
               "level" => "error",
               "subsystem" => "providers",
               "message" => unquote(fixture)
             }
           ],
           "count" => 1,
           "truncated" => false,
           "cursor" => nil
         }}
      end

      assert {:ok, report} = Diagnostics.build(opts(logs_provider: logs_provider))
      encoded = Jason.encode!(report)

      refute encoded =~ unquote(absent)
      assert encoded =~ "REDACTED"
    end
  end

  # `doctor.get` hands summaries straight to the app, and `diagnostics.build`
  # exports the same strings. Two scrubbers means the app reads raw what the
  # export redacts, which is the opposite of what the descriptor's own contract
  # claims.
  for {label, fixture, absent} <- @secret_fixtures do
    test "a Doctor summary crossing doctor.get excludes #{label}" do
      summary = Descriptor.summary(unquote(fixture))

      refute summary =~ unquote(absent)
      assert summary =~ "REDACTED"
    end
  end

  test "an unexpected key from a source never reaches the object" do
    doctor_provider = fn ->
      view =
        doctor_view("all good")
        |> Map.put("transcript", "the owner said something private")
        |> Map.put("database_path", "/Users/rae/.fermix/memory.db")

      {:ok, view}
    end

    assert {:ok, report} = Diagnostics.build(opts(doctor_provider: doctor_provider))

    assert Map.keys(report["doctor"]) |> Enum.sort() ==
             ~w(checks finished_at scope session_id status)

    refute Jason.encode!(report) =~ "the owner said something private"
  end

  defp opts(overrides \\ []) do
    defaults = [
      identity_provider: fn -> {:ok, @identity} end,
      service_provider: fn -> {:ok, %{scope: :user, state: :installed}} end,
      doctor_provider: fn -> {:ok, doctor_view("readiness is ready")} end,
      logs_provider: fn _params ->
        {:ok,
         %{
           "entries" => [
             %{
               "time" => "2026-08-19T10:00:00.000000",
               "level" => "info",
               "subsystem" => "boot",
               "message" => "daemon started"
             }
           ],
           "count" => 1,
           "truncated" => false,
           "cursor" => nil
         }}
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  defp doctor_view(summary) do
    %{
      "session_id" => "doctor:abc",
      "scope" => "local",
      "status" => "completed",
      "started_at" => "2026-08-19T10:00:00Z",
      "finished_at" => "2026-08-19T10:00:03Z",
      "budget_ms" => 10_000,
      "duration_ms" => 3_000,
      "total" => 1,
      "summary" => %{"passed" => 1},
      "checks" => [
        %{
          "id" => "readiness",
          "category" => "runtime",
          "severity" => "critical",
          "applicability" => "always",
          "origin" => "engine",
          "status" => "passed",
          "summary" => summary,
          "evidence" => %{"source_name" => "readiness", "source_status" => "ok"},
          "remediation_code" => nil,
          "duration_ms" => 4,
          "finished_at" => "2026-08-19T10:00:01Z"
        }
      ]
    }
  end
end
