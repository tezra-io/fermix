defmodule FermixCore.Providers.RoutingOverridesTest do
  # async: false — subagent/0, cron/0, infer_provider/1 read shared Application env.
  use ExUnit.Case, async: false

  alias FermixCore.Providers.RoutingOverrides

  @empty %{provider: nil, model: nil, reasoning_effort: nil}

  setup do
    routing = Application.get_env(:fermix_core, :routing, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    providers = Application.get_env(:fermix_core, :providers, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :routing, routing)
      Application.put_env(:fermix_core, :agent, agent)
      Application.put_env(:fermix_core, :providers, providers)
    end)

    :ok
  end

  describe "parse/2 (pure)" do
    test "reads and validates the prefixed keys" do
      routing = [
        subagent_provider: "openai",
        subagent_model: "gpt-5.4-mini",
        subagent_reasoning_effort: "low",
        cron_model: "claude-haiku-4-5"
      ]

      assert RoutingOverrides.parse(routing, :subagent) == %{
               provider: :openai,
               model: "gpt-5.4-mini",
               reasoning_effort: :low
             }

      assert RoutingOverrides.parse(routing, :cron) == %{
               provider: nil,
               model: "claude-haiku-4-5",
               reasoning_effort: nil
             }
    end

    test "missing keys and empty strings become nil" do
      assert RoutingOverrides.parse([], :subagent) == @empty

      assert RoutingOverrides.parse([subagent_model: "", subagent_provider: ""], :subagent) ==
               @empty
    end

    test "an unknown provider raises naming the key and value" do
      assert_raise ArgumentError, ~r/\[fermix_core.routing\] subagent_provider = "nope"/, fn ->
        RoutingOverrides.parse([subagent_provider: "nope"], :subagent)
      end
    end

    test "an invalid effort raises naming the key and value" do
      assert_raise ArgumentError,
                   ~r/\[fermix_core.routing\] cron_reasoning_effort = "turbo"/,
                   fn ->
                     RoutingOverrides.parse([cron_reasoning_effort: "turbo"], :cron)
                   end
    end
  end

  describe "parse_tool_args/1 (pure)" do
    test "parses a per-call override without inferring the provider" do
      assert RoutingOverrides.parse_tool_args(%{
               "model" => "gpt-5.5",
               "reasoning_effort" => "high"
             }) ==
               %{provider: nil, model: "gpt-5.5", reasoning_effort: :high}
    end

    test "validates an explicit provider and effort, raising on bad input" do
      assert %{provider: :anthropic} =
               RoutingOverrides.parse_tool_args(%{"provider" => "anthropic", "model" => "x"})

      assert_raise ArgumentError, ~r/subagents argument "provider" = "gpt-5-mini"/, fn ->
        RoutingOverrides.parse_tool_args(%{"provider" => "gpt-5-mini"})
      end

      assert_raise ArgumentError, ~r/subagents argument "reasoning_effort" = "bananas"/, fn ->
        RoutingOverrides.parse_tool_args(%{"reasoning_effort" => "bananas"})
      end
    end

    test "an empty args map yields all-nil" do
      assert RoutingOverrides.parse_tool_args(%{}) == @empty
    end
  end

  describe "merge/2 (pure, field-level)" do
    test "each set field of the call wins; unset falls through to config" do
      call = %{provider: nil, model: "gpt-5.5", reasoning_effort: nil}
      config = %{provider: :openai, model: "gpt-5.4-mini", reasoning_effort: :low}

      # The call's model overrides; the configured effort survives.
      assert RoutingOverrides.merge(call, config) == %{
               provider: :openai,
               model: "gpt-5.5",
               reasoning_effort: :low
             }
    end

    test "an empty call leaves config untouched" do
      config = %{provider: :anthropic, model: "claude-opus-4-8", reasoning_effort: :high}
      assert RoutingOverrides.merge(@empty, config) == config
    end
  end

  describe "apply_effort/2 (pure)" do
    test "nil leaves routes unchanged" do
      routes = [{%{provider: :openai, model: "gpt-5.5"}, [model: "gpt-5.5"]}]
      assert RoutingOverrides.apply_effort(routes, nil) == routes
    end

    test "overlays a clamped effort per route provider, preserving model and chain" do
      routes = [
        {%{provider: :openai, model: "gpt-5.5"}, [model: "gpt-5.5", reasoning_effort: :medium]},
        {%{provider: :xai, model: "grok-4.3"}, [model: "grok-4.3"]}
      ]

      assert [
               {%{provider: :openai}, openai_opts},
               {%{provider: :xai}, xai_opts}
             ] = RoutingOverrides.apply_effort(routes, :max)

      # :max clamps to each provider's ceiling: openai -> :xhigh, xai -> :high.
      assert Keyword.get(openai_opts, :reasoning_effort) == :xhigh
      assert Keyword.get(openai_opts, :model) == "gpt-5.5"
      assert Keyword.get(xai_opts, :reasoning_effort) == :high
    end

    # M12 §5.2 effort contract: routes whose provider has no levels entry
    # are left untouched — never stamped with an effort their adapter
    # would have to ignore.
    test "skips routes whose provider has no reasoning-effort levels" do
      routes = [
        {%{provider: :openai, model: "gpt-5.5"}, [model: "gpt-5.5"]},
        {%{provider: :no_levels_provider, model: "some-model"}, [model: "some-model"]}
      ]

      assert [
               {%{provider: :openai}, openai_opts},
               {%{provider: :no_levels_provider}, bare_opts}
             ] = RoutingOverrides.apply_effort(routes, :high)

      assert Keyword.get(openai_opts, :reasoning_effort) == :high
      refute Keyword.has_key?(bare_opts, :reasoning_effort)
    end
  end

  describe "infer_provider/1 (reads primary)" do
    test "leaves an already-set provider or a model-less override untouched" do
      set = %{provider: :anthropic, model: "claude-opus-4-8", reasoning_effort: nil}
      assert RoutingOverrides.infer_provider(set) == set
      assert RoutingOverrides.infer_provider(@empty) == @empty
    end

    test "infers an unambiguous cross-provider slug regardless of primary" do
      Application.put_env(:fermix_core, :providers, [])
      Application.put_env(:fermix_core, :agent, provider: :openai)

      assert %{provider: :anthropic} =
               RoutingOverrides.infer_provider(%{
                 provider: nil,
                 model: "claude-opus-4-8",
                 reasoning_effort: nil
               })
    end

    test "prefers the primary provider for a slug shared across catalogs" do
      Application.put_env(:fermix_core, :providers, [])

      # gpt-5.5 is in both :openai_codex and :openai catalogs; primary breaks the tie.
      Application.put_env(:fermix_core, :agent, provider: :openai)

      assert %{provider: :openai} =
               RoutingOverrides.infer_provider(%{
                 provider: nil,
                 model: "gpt-5.5",
                 reasoning_effort: nil
               })

      Application.put_env(:fermix_core, :agent, provider: :openai_codex)

      assert %{provider: :openai_codex} =
               RoutingOverrides.infer_provider(%{
                 provider: nil,
                 model: "gpt-5.5",
                 reasoning_effort: nil
               })
    end
  end

  describe "subagent/0 and cron/0 (read app env)" do
    test "read the live routing config" do
      Application.put_env(:fermix_core, :routing,
        subagent_model: "gpt-5.4-mini",
        cron_reasoning_effort: "low"
      )

      assert RoutingOverrides.subagent() == %{
               provider: nil,
               model: "gpt-5.4-mini",
               reasoning_effort: nil
             }

      assert RoutingOverrides.cron() == %{provider: nil, model: nil, reasoning_effort: :low}
    end

    test "absent routing config yields all-nil" do
      Application.put_env(:fermix_core, :routing, [])
      assert RoutingOverrides.subagent() == @empty
      assert RoutingOverrides.cron() == @empty
    end
  end
end
