defmodule FermixOpik.MapperTest do
  use ExUnit.Case, async: true

  alias FermixOpik.Mapper

  @ended ~U[2026-06-02 12:00:03.200Z]

  test "llm_span carries model, provider, and OpenAI-style usage for auto-cost" do
    metadata = %{
      provider: :openai_codex,
      model: "gpt-5-codex",
      status: :ok,
      tokens: %{prompt: 100, completion: 25}
    }

    span =
      Mapper.llm_span(metadata, %{duration_ms: 1_200},
        trace_id: "trace-1",
        parent_span_id: "wrap-1",
        project_name: "fermix",
        ended: @ended
      )

    assert span.type == "llm"
    assert span.trace_id == "trace-1"
    assert span.parent_span_id == "wrap-1"
    assert span.model == "gpt-5-codex"
    # Codex maps to the "openai" pricing provider Opik recognizes
    assert span.provider == "openai"
    assert span.usage == %{prompt_tokens: 100, completion_tokens: 25, total_tokens: 125}
    assert span.start_time == "2026-06-02T12:00:02.000Z"
    assert span.end_time == "2026-06-02T12:00:03.200Z"
  end

  test "llm_span renders a media provider failure as an adapter-qualified, errored span" do
    # Shape emitted by Media.Support.with_provider_call on a failed image gen:
    # adapter set (so the name is qualified), zero tokens (no phantom cost),
    # error_code/error_summary (so it renders red, not green).
    metadata = %{
      provider: :openai,
      adapter: :openai,
      model: "gpt-image-2",
      status: :error,
      tokens: %{},
      error_code: "auth_failed",
      error_summary: "auth_failed: HTTP 401"
    }

    span =
      Mapper.llm_span(metadata, %{duration_ms: 448},
        trace_id: "trace-1",
        project_name: "fermix",
        ended: @ended
      )

    # Adapter-qualified, so it is filterable and distinct from chat llm spans.
    assert span.name == "llm:openai:gpt-image-2"
    # Flagged as errored — the whole point of the fix.
    assert span.error_info == %{exception_type: "auth_failed", message: "auth_failed: HTTP 401"}
    # Zero-token image call carries no usage (no phantom Opik cost) but is still a real span.
    refute Map.has_key?(span, :usage)
    assert span.metadata.status == "error"
    assert span.metadata.adapter == :openai
  end

  test "tool_span records name, type, and preserves plugin metadata" do
    metadata = %{tool: "shell", success: true, plugin: "builtin", action: "navigate"}

    span =
      Mapper.tool_span(metadata, %{duration_ms: 50},
        trace_id: "trace-1",
        parent_span_id: "wrap-1",
        project_name: "fermix",
        ended: @ended
      )

    assert span.type == "tool"
    assert span.name == "shell"
    assert span.metadata == %{plugin: "builtin", action: "navigate"}
  end

  test "content fields wrap into Opik input/output when present" do
    metadata = %{tool: "shell", input: "ls -la", output: "a\nb"}

    span =
      Mapper.tool_span(metadata, %{duration_ms: 10},
        trace_id: "t",
        parent_span_id: nil,
        project_name: "fermix",
        ended: @ended
      )

    assert span.input == %{text: "ls -la"}
    assert span.output == %{text: "a\nb"}
    refute Map.has_key?(span, :parent_span_id)
  end

  test "error metadata becomes error_info" do
    metadata = %{tool: "file_read", success: false, error: "not found"}

    span =
      Mapper.tool_span(metadata, %{duration_ms: 1},
        trace_id: "t",
        project_name: "fermix",
        ended: @ended
      )

    assert span.error_info == %{exception_type: "ToolError", message: "not found"}
  end

  test "tool_span preserves the browser/shell safe diagnostics" do
    metadata = %{
      tool: "browser",
      success: true,
      action: "click",
      kind: "interaction",
      profile: "default",
      url: "https://example.com/page",
      target_ref: "ref-7",
      selector: "#submit"
    }

    span =
      Mapper.tool_span(metadata, %{duration_ms: 30},
        trace_id: "t",
        project_name: "fermix",
        ended: @ended
      )

    assert span.metadata == %{
             action: "click",
             kind: "interaction",
             profile: "default",
             url: "https://example.com/page",
             target_ref: "ref-7",
             selector: "#submit"
           }
  end

  # The eval harness proves "the dangerous command never ran" from this marker
  # alone; dropping it here is indistinguishable from no enforcement at all.
  test "tool_span exports typed pre-execution policy evidence" do
    metadata = %{
      tool: "shell",
      success: false,
      failure: "hardline",
      policy_enforcement: %{
        source: "sandbox",
        decision: "hardline",
        phase: "pre_execution"
      }
    }

    span =
      Mapper.tool_span(metadata, %{duration_ms: 1},
        trace_id: "t",
        project_name: "fermix",
        ended: @ended
      )

    assert span.metadata == %{
             policy_enforcement: %{
               source: "sandbox",
               decision: "hardline",
               phase: "pre_execution"
             }
           }
  end

  test "tool_span routes error_code/error_summary into error_info" do
    metadata = %{
      tool: "browser",
      success: false,
      action: "click",
      error_code: "element_not_found",
      error_summary: "no node matched #submit"
    }

    span =
      Mapper.tool_span(metadata, %{duration_ms: 5},
        trace_id: "t",
        project_name: "fermix",
        ended: @ended
      )

    assert span.error_info == %{
             exception_type: "element_not_found",
             message: "no node matched #submit"
           }

    # The structural diagnostic still rides as metadata; the error pair does not.
    assert span.metadata == %{action: "click"}
  end

  test "usage tolerates *_tokens keys and derives total" do
    assert Mapper.usage(%{prompt_tokens: 3, completion_tokens: 7}) ==
             %{prompt_tokens: 3, completion_tokens: 7, total_tokens: 10}

    assert Mapper.usage(%{}) == nil
    assert Mapper.usage(nil) == nil
  end

  test "provider_string maps every Fermix provider to an Opik pricing token" do
    assert Mapper.provider_string(:openai) == "openai"
    assert Mapper.provider_string(:openai_codex) == "openai"
    assert Mapper.provider_string(:anthropic) == "anthropic"
    assert Mapper.provider_string(:xai) == "xai"
    assert Mapper.provider_string(:openrouter) == "openrouter"
    assert Mapper.provider_string(:ollama) == "ollama"
    assert Mapper.provider_string(:mistral) == "mistral"
    assert Mapper.provider_string(nil) == nil
  end

  test "realtime_span builds a general lifecycle point span" do
    span =
      Mapper.realtime_span(
        %{device_id: "dev-1", model: "gpt-realtime-2", voice: "marin", reason: "boom"},
        %{},
        trace_id: "trace-1",
        parent_span_id: "wrap-1",
        project_name: "fermix",
        ended: @ended,
        phase: :provider_error
      )

    assert span.name == "realtime:provider_error"
    assert span.type == "general"
    assert span.trace_id == "trace-1"
    assert span.parent_span_id == "wrap-1"
    assert span.metadata.reason == "boom"
    assert span.metadata.model == "gpt-realtime-2"
  end

  # The outbound MCP server identity is already stamped on every MCP tool exec by
  # `MCP.Capability.invoke/6`; before this key was allowlisted it was dropped from
  # every Opik tool span (each builder hard-codes its own key set — there is no
  # global allowlist).
  # MILESTONE_31 §16: the search family's bounded metadata. `location_mode` is the
  # only record of WHICH anchor a place search used — the coordinates themselves
  # never leave the outbound request — so dropping it here erases the privacy
  # evidence, not just a nice-to-have field.
  test "tool_span keeps the search-family backend, counts, and anchor mode" do
    metadata = %{
      tool: "place_search",
      success: true,
      backend: "brave",
      result_count: 5,
      has_media_count: 4,
      location_mode: "named"
    }

    span =
      Mapper.tool_span(metadata, %{duration_ms: 120},
        trace_id: "t",
        project_name: "fermix",
        ended: @ended
      )

    assert span.metadata == %{
             backend: "brave",
             result_count: 5,
             has_media_count: 4,
             location_mode: "named"
           }
  end

  test "tool_span keeps the outbound MCP server identity" do
    metadata = %{tool: "eden_get_note_markdown", success: true, mcp_server: "eden"}

    span =
      Mapper.tool_span(metadata, %{duration_ms: 30},
        trace_id: "t",
        project_name: "fermix",
        ended: @ended
      )

    assert span.metadata.mcp_server == "eden"
  end

  describe "mcp_client_span/3" do
    test "builds a general lifecycle point span from the emitter's allowlist" do
      metadata = %{
        source_id: "plugin:eden",
        plugin: "eden",
        phase: :security_block,
        result: :error,
        error_class: "tool_not_allowed",
        attempt: 2,
        session_id: "main-7"
      }

      span =
        Mapper.mcp_client_span(metadata, %{duration_ms: 12},
          trace_id: "trace-1",
          parent_span_id: "wrap-1",
          project_name: "fermix",
          ended: @ended
        )

      assert span.name == "mcp_client:security_block"
      assert span.type == "general"
      assert span.trace_id == "trace-1"
      assert span.parent_span_id == "wrap-1"
      assert span.start_time == "2026-06-02T12:00:03.188Z"
      assert span.end_time == "2026-06-02T12:00:03.200Z"

      assert span.metadata == %{
               source_id: "plugin:eden",
               plugin: "eden",
               phase: "security_block",
               result: "error",
               error_class: "tool_not_allowed",
               attempt: 2
             }
    end

    # The span builder is the last gate before export: a key it does not name is
    # silently dropped, and that is what must stay true for anything sensitive.
    test "an unlisted metadata key never exports" do
      metadata = %{
        source_id: "plugin:eden",
        phase: :ready,
        result: :ok,
        authorization: "Bearer eden_pat_fakevalue",
        mcp_session_id: "mcp-sess-01JFAKE",
        workspace_id: "ws_fake_0123456789",
        base_url: "https://mcp.eden.so/mcp"
      }

      span =
        Mapper.mcp_client_span(metadata, %{duration_ms: 0},
          trace_id: "t",
          project_name: "fermix",
          ended: @ended
        )

      assert span.metadata == %{source_id: "plugin:eden", phase: "ready", result: "ok"}
      refute String.contains?(inspect(span), "eden_pat_fakevalue")
      refute String.contains?(inspect(span), "mcp-sess")
      refute String.contains?(inspect(span), "ws_fake")
      refute String.contains?(inspect(span), "mcp.eden.so")
    end
  end
end
