defmodule FermixCore.Tools.TelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  # A synthetic stand-in for the ACP session's BUZZ_PRIVATE_KEY/NOSTR_PRIVATE_KEY:
  # long enough to clear the scrub floor, never a real credential.
  @planted "nsec1fakebuzzkeyvalue"

  setup do
    handler = "tool-tel-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:tool_exec, measurements, metadata})
      end,
      nil
    )

    prior = Application.get_env(:fermix_core, :telemetry, [])

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:fermix_core, :telemetry, prior)
    end)

    :ok
  end

  defp set_capture_content(value) do
    Application.put_env(:fermix_core, :telemetry, capture_content: value)
  end

  defp redacting_context do
    %{agent_name: "main", session_id: "main-1", redact_values: [@planted]}
  end

  defp nest(0, leaf), do: leaf
  defp nest(depth, leaf) when depth > 0, do: %{inner: nest(depth - 1, leaf)}

  defp leaf(%{inner: inner}), do: leaf(inner)
  defp leaf(value), do: value

  test "emits agent and correlation ids from context" do
    context = %{
      agent_name: "scheduled:job-1",
      session_id: "cron_job-1_42",
      parent_session: "main-7"
    }

    ToolTelemetry.exec("shell", context, true, 12, metadata: %{plugin: "builtin"})

    assert_receive {:tool_exec, %{duration_ms: 12}, metadata}
    assert metadata.tool == "shell"
    assert metadata.agent == "scheduled:job-1"
    assert metadata.success == true
    assert metadata.session_id == "cron_job-1_42"
    assert metadata.parent_session == "main-7"
    assert metadata.plugin == "builtin"
  end

  test "defaults agent to unknown and omits absent correlation ids" do
    ToolTelemetry.exec("file_read", %{}, false, 3)

    assert_receive {:tool_exec, _measurements, metadata}
    assert metadata.agent == "unknown"
    refute Map.has_key?(metadata, :session_id)
    refute Map.has_key?(metadata, :parent_session)
  end

  test "a caller cannot override authoritative fields via metadata" do
    context = %{agent_name: "main", session_id: "main-1"}

    ToolTelemetry.exec("file_write", context, true, 5,
      metadata: %{tool: "spoofed", agent: "evil", success: false}
    )

    assert_receive {:tool_exec, _measurements, metadata}
    assert metadata.tool == "file_write"
    assert metadata.agent == "main"
    assert metadata.success == true
  end

  test "content is omitted when capture is disabled" do
    set_capture_content(false)
    context = %{agent_name: "main", session_id: "main-1"}

    ToolTelemetry.exec("shell", context, true, 5, input: "ls -la", output: "file listing")

    assert_receive {:tool_exec, _measurements, metadata}
    refute Map.has_key?(metadata, :input)
    refute Map.has_key?(metadata, :output)
  end

  test "content is attached whole when capture is enabled" do
    set_capture_content(true)
    context = %{agent_name: "main", session_id: "main-1"}
    big_output = String.duplicate("x", 5_000)

    ToolTelemetry.exec("shell", context, true, 5, input: "ls -la", output: big_output)

    assert_receive {:tool_exec, _measurements, metadata}
    assert metadata.input == "ls -la"
    # Capture on means full fidelity — no 2k truncation (that bound applies
    # only when capture is off; see FermixCore.TelemetryTest).
    assert metadata.output == big_output
  end

  # MILESTONE_29_ACP_AGENT_SURFACE §8.3: the ACP session's two credential values
  # ride the turn context as `:redact_values` and are scrubbed here — the single
  # choke point every tool's content preview passes through.
  describe "redact_values scrubbing" do
    test "replaces every occurrence of a redacted value in both previews" do
      set_capture_content(true)
      secret = "nsec1fakebuzzkeyvalue"

      context = %{
        agent_name: "main",
        session_id: "main-1",
        redact_values: [secret]
      }

      ToolTelemetry.exec("shell", context, true, 5,
        input: "echo $BUZZ_PRIVATE_KEY # #{secret}",
        output: "#{secret} and again #{secret}"
      )

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.input == "echo $BUZZ_PRIVATE_KEY # «redacted»"
      assert metadata.output == "«redacted» and again «redacted»"
    end

    test "previews are byte-identical when the context carries no redact_values" do
      set_capture_content(true)
      context = %{agent_name: "main", session_id: "main-1"}
      input = "ls -la"
      output = "total 0\ndrwxr-xr-x  2 user  staff  64 Jul 30 10:00 ."

      ToolTelemetry.exec("shell", context, true, 5, input: input, output: output)

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.input == input
      assert metadata.output == output
    end

    test "an empty redact list leaves previews untouched" do
      set_capture_content(true)
      context = %{agent_name: "main", session_id: "main-1", redact_values: []}

      ToolTelemetry.exec("shell", context, true, 5, input: "pwd", output: "/tmp")

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.input == "pwd"
      assert metadata.output == "/tmp"
    end

    # A short value would shred unrelated output (a 2-byte "ab" appears
    # everywhere), so anything under the floor is never scrubbed.
    test "values shorter than the scrub floor are left alone" do
      set_capture_content(true)
      context = %{agent_name: "main", session_id: "main-1", redact_values: ["abc"]}

      ToolTelemetry.exec("shell", context, true, 5, input: "abcdef", output: "xyzabc")

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.input == "abcdef"
      assert metadata.output == "xyzabc"
    end
  end

  # The previews above are gated on `capture_content?/0`, but caller-supplied
  # `:metadata` is attached on EVERY emit — so a free-form metadata field is the
  # always-on leak path, and it gets the same redaction, floor and marker.
  describe "metadata scrubbing" do
    # Key names mirror `Tools.Shell`: `:command` is the verbatim command text and
    # `:error_summary` is derived from the tool error, which on a non-zero exit
    # embeds the child's stdout.
    test "shell-shaped metadata is scrubbed when capture_content is off" do
      set_capture_content(false)

      ToolTelemetry.exec("shell", redacting_context(), false, 5,
        metadata: %{
          command: "buzz post --key #{@planted}",
          error_summary: "Command failed (exit code 1):\nrejected key #{@planted}",
          exit_code: 1
        }
      )

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.command == "buzz post --key «redacted»"
      assert metadata.error_summary == "Command failed (exit code 1):\nrejected key «redacted»"
      assert metadata.exit_code == 1
    end

    test "shell-shaped metadata is scrubbed when capture_content is on" do
      set_capture_content(true)

      ToolTelemetry.exec("shell", redacting_context(), false, 5,
        metadata: %{command: "buzz post --key #{@planted}"}
      )

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.command == "buzz post --key «redacted»"
    end

    test "nested maps and lists inside metadata are scrubbed" do
      set_capture_content(false)

      ToolTelemetry.exec("shell", redacting_context(), false, 5,
        metadata: %{
          policy_enforcement: %{source: "sandbox", detail: "denied #{@planted}"},
          argv: ["buzz", "--key", @planted, %{note: "again #{@planted}"}]
        }
      )

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.policy_enforcement == %{source: "sandbox", detail: "denied «redacted»"}
      assert metadata.argv == ["buzz", "--key", "«redacted»", %{note: "again «redacted»"}]
    end

    test "every occurrence in a metadata value is replaced" do
      set_capture_content(false)

      ToolTelemetry.exec("shell", redacting_context(), false, 5,
        metadata: %{command: "#{@planted} && echo #{@planted} && rm #{@planted}"}
      )

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.command == "«redacted» && echo «redacted» && rm «redacted»"
    end

    test "metadata values shorter than the scrub floor are left alone" do
      set_capture_content(false)
      context = %{agent_name: "main", session_id: "main-1", redact_values: ["abc"]}

      ToolTelemetry.exec("shell", context, false, 5, metadata: %{command: "abcdef"})

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.command == "abcdef"
    end

    test "non-binary metadata values pass through untouched" do
      set_capture_content(false)
      owner = self()
      stamp = ~U[2026-07-30 10:00:00Z]

      ToolTelemetry.exec("shell", redacting_context(), false, 5,
        metadata: %{
          exit_code: 1,
          failure: :exit_nonzero,
          ratio: 1.5,
          truthy: true,
          absent: nil,
          pair: {:error, :timeout},
          owner: owner,
          at: stamp
        }
      )

      assert_receive {:tool_exec, _measurements, metadata}
      assert metadata.exit_code == 1
      assert metadata.failure == :exit_nonzero
      assert metadata.ratio == 1.5
      assert metadata.truthy == true
      assert metadata.absent == nil
      assert metadata.pair == {:error, :timeout}
      assert metadata.owner == owner
      assert metadata.at == stamp
    end

    test "metadata is unchanged when the context carries no redact_values" do
      set_capture_content(false)

      assert_metadata_unchanged(%{agent_name: "main", session_id: "main-1"})
    end

    test "metadata is unchanged when redact_values is empty" do
      set_capture_content(false)

      assert_metadata_unchanged(%{agent_name: "main", session_id: "main-1", redact_values: []})
    end

    # The walk is depth-capped (`@max_scrub_depth`): past the cap a value is
    # handed through unchanged — the cap bounds the work, it never crashes or
    # truncates. No real tool's metadata nests anywhere near it.
    test "a value nested past the depth cap is passed through unchanged" do
      set_capture_content(false)

      ToolTelemetry.exec("shell", redacting_context(), false, 5,
        metadata: %{
          shallow: nest(2, "leaf #{@planted}"),
          deep: nest(30, "leaf #{@planted}")
        }
      )

      assert_receive {:tool_exec, _measurements, metadata}
      assert leaf(metadata.shallow) == "leaf «redacted»"
      assert leaf(metadata.deep) == "leaf #{@planted}"
    end
  end

  defp assert_metadata_unchanged(context) do
    original = %{
      command: "ls -la",
      policy_enforcement: %{source: "sandbox", decision: "deny"},
      argv: ["sh", "-c", "ls"],
      pair: {:ok, 0},
      at: ~U[2026-07-30 10:00:00Z],
      exit_code: 0
    }

    ToolTelemetry.exec("shell", context, true, 5, metadata: original)

    assert_receive {:tool_exec, _measurements, metadata}
    assert Map.take(metadata, Map.keys(original)) == original
  end

  test "a failed result's error text is previewed as output when capture is enabled" do
    set_capture_content(true)
    context = %{agent_name: "main", session_id: "main-1"}
    # Builtin failures (Tool.error/1) carry output: "" — the error text is the
    # body worth tracing, and an empty output must not shadow it.
    error_text = "boom (code): {\"console\":[]}"
    result = {:ok, %{success: false, output: "", error: error_text}}

    ToolTelemetry.exec("browser", context, false, 5, result: result)

    assert_receive {:tool_exec, _measurements, metadata}
    assert metadata.output == error_text
  end
end
