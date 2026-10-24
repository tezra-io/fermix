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

  test "the main model is labelled with the primary and the model it runs" do
    snapshot =
      snapshot(
        anthropic: [api_key: "sk-ant-invented", primary: true, default_model: "claude-sonnet-5-5"],
        openai: [api_key: "sk-invented", default_model: "gpt-5.4-mini"]
      )

    assert FilterChoices.main_model_label(snapshot) ==
             "Main model (#{Descriptor.fetch!(:anthropic).label} · claude-sonnet-5-5)"
  end

  test "a primary with no model chosen yet is named alone" do
    snapshot = snapshot(openai_codex: [primary: true])

    assert FilterChoices.main_model_label(snapshot) ==
             "Main model (#{Descriptor.fetch!(:openai_codex).label})"
  end

  test "two primaries name no model rather than guess one" do
    snapshot =
      snapshot(
        anthropic: [api_key: "sk-ant-invented", primary: true],
        openai: [api_key: "sk-invented", primary: true]
      )

    assert FilterChoices.main_model_label(snapshot) == "Main model"
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

  test "models are the catalog's suggestions, none for an unknown provider" do
    assert [%{id: _id, label: _label} | _more] = FilterChoices.models("anthropic")
    assert FilterChoices.models("nope") == []
  end
end
