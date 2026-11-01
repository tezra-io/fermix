defmodule FermixCore.Cues.FilterChoicesTest do
  # async: false — sets FERMIX_HOME, where the auth store a provider's OAuth
  # sign-in is read from lives, to an empty directory of its own.
  use ExUnit.Case, async: false

  alias FermixCore.Cues.FilterChoices
  alias FermixCore.Providers.Descriptor
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("filter-choices")
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      if previous,
        do: System.put_env("FERMIX_HOME", previous),
        else: System.delete_env("FERMIX_HOME")

      SafeRm.rm_rf!(home)
    end)

    :ok
  end

  defp snapshot(providers, agent \\ []),
    do: %{fermix_core: [providers: providers, agent: agent]}

  # The default option names what it resolves to, from the owner's own
  # settings (M60_CUE_INTAKE_AT_SCALE.md §3.7): no per-provider list to keep.
  test "the main model is labelled with the primary and the model it runs" do
    snapshot =
      snapshot(
        anthropic: [api_key: "sk-ant-invented", primary: true, default_model: "claude-sonnet-5-5"],
        openai: [api_key: "sk-invented", default_model: "gpt-5.4-mini"]
      )

    assert FilterChoices.main_model_label(snapshot) ==
             "Default: your main model (#{Descriptor.fetch!(:anthropic).label} · claude-sonnet-5-5)"
  end

  test "a primary with no model chosen yet is named alone" do
    snapshot = snapshot(openai_codex: [primary: true])

    assert FilterChoices.main_model_label(snapshot) ==
             "Default: your main model (#{Descriptor.fetch!(:openai_codex).label})"
  end

  test "two primaries name no model rather than guess one" do
    snapshot =
      snapshot(
        anthropic: [api_key: "sk-ant-invented", primary: true],
        openai: [api_key: "sk-invented", primary: true]
      )

    assert FilterChoices.main_model_label(snapshot) == "Default: your main model"
  end

  test "only the providers that are set up are offered, in catalog order" do
    snapshot =
      snapshot(
        anthropic: [api_key: "sk-ant-invented", primary: true],
        openai: [api_key: "sk-invented"],
        mistral: [default_model: "mistral-large-latest"]
      )

    assert Enum.map(FilterChoices.providers(snapshot), & &1.id) == ["openai", "anthropic"]
    assert %{id: "openai", label: label} = hd(FilterChoices.providers(snapshot))
    assert label == Descriptor.fetch!(:openai).label
  end

  describe "the screen" do
    test "keyword match, then the decision model of a primary that serves one" do
      snapshot =
        snapshot(
          openai: [api_key: "sk-invented"],
          openrouter: [api_key: "sk-or-invented", primary: true]
        )

      assert FilterChoices.decision_model(snapshot) ==
               %{provider: :openrouter, label: "OpenRouter · Jev"}

      assert FilterChoices.screen_choices(snapshot) == [
               %{id: "keyword", label: "Keyword match", hint: nil, disabled?: false},
               %{
                 id: "decision_model",
                 label: "Decision model",
                 hint: "Uses OpenRouter · Jev",
                 disabled?: false
               }
             ]
    end

    test "under a primary that serves none, the first set up in catalog order" do
      snapshot =
        snapshot(
          anthropic: [api_key: "sk-ant-invented", primary: true],
          venice: [api_key: "vn-invented"],
          openai: [api_key: "sk-invented"]
        )

      assert %{provider: :openai, label: "OpenAI · gpt-6-luna"} =
               FilterChoices.decision_model(snapshot)
    end

    test "with none set up, the decision model is disabled with what to set up" do
      snapshot =
        snapshot(
          anthropic: [api_key: "sk-ant-invented", primary: true],
          venice: [default_model: "venice-uncensored"]
        )

      assert FilterChoices.decision_model(snapshot) == nil

      assert %{id: "decision_model", disabled?: true, hint: hint} =
               List.last(FilterChoices.screen_choices(snapshot))

      assert hint == "Set up OpenAI, OpenRouter or Venice first."
    end

    test "a key that did not load is not set up" do
      snapshot =
        snapshot(
          openrouter: [api_key: "@keyring", primary: true],
          venice: [api_key: "@file"]
        )

      assert FilterChoices.decision_model(snapshot) == nil
      assert %{disabled?: true} = List.last(FilterChoices.screen_choices(snapshot))
    end

    test "a chosen decision model that is not set up is named as what to set up, never as in use" do
      snapshot =
        Map.update!(
          snapshot(openai: [api_key: "sk-invented"], venice: [api_key: "@keyring"]),
          :fermix_core,
          &Keyword.put(&1, :cues, decision_provider: :venice)
        )

      assert List.last(FilterChoices.screen_choices(snapshot)) == %{
               id: "decision_model",
               label: "Decision model",
               hint: "Set up Venice first: the screen's decision model runs on its key.",
               disabled?: false
             }
    end

    test "a chosen decision model is the one the screen names" do
      snapshot =
        Map.update!(
          snapshot(openai: [api_key: "sk-invented"], venice: [api_key: "vn-invented"]),
          :fermix_core,
          &Keyword.put(&1, :cues, decision_provider: :venice)
        )

      assert %{hint: "Uses Venice · Jev", disabled?: false} =
               List.last(FilterChoices.screen_choices(snapshot))
    end
  end

  describe "the screen's decision model" do
    test "Automatic names what it resolves to, then each provider, one not set up disabled" do
      snapshot =
        snapshot(
          anthropic: [api_key: "sk-ant-invented", primary: true],
          openai: [api_key: "sk-invented"],
          openrouter: [api_key: "@keyring"]
        )

      assert FilterChoices.decision_provider_choices(snapshot) == [
               %{
                 id: "",
                 label: "Automatic (Uses OpenAI · gpt-6-luna)",
                 hint: nil,
                 disabled?: false
               },
               %{id: "openai", label: "OpenAI · gpt-6-luna", hint: nil, disabled?: false},
               %{
                 id: "openrouter",
                 label: "OpenRouter · Jev",
                 hint: "Set up this provider first.",
                 disabled?: true
               },
               %{
                 id: "venice",
                 label: "Venice · Jev",
                 hint: "Set up this provider first.",
                 disabled?: true
               }
             ]
    end

    test "with none set up, Automatic is disabled with what to set up" do
      snapshot = snapshot(anthropic: [api_key: "sk-ant-invented", primary: true])

      assert [automatic | providers] = FilterChoices.decision_provider_choices(snapshot)

      assert automatic == %{
               id: "",
               label: "Automatic",
               hint: "Set up OpenAI, OpenRouter or Venice first.",
               disabled?: true
             }

      assert Enum.all?(providers, & &1.disabled?)
    end

    test "a provider is set up for it only with a key that loaded" do
      snapshot = snapshot(openai: [api_key: "sk-invented"], venice: [api_key: "@file"])

      assert FilterChoices.decision_model_set_up?(snapshot, :openai)
      refute FilterChoices.decision_model_set_up?(snapshot, :venice)
      refute FilterChoices.decision_model_set_up?(snapshot, :openrouter)
    end
  end

  test "models are the catalog's suggestions, none for an unknown provider" do
    assert [%{id: _id, label: _label} | _more] = FilterChoices.models("anthropic")
    assert FilterChoices.models("nope") == []
  end
end
