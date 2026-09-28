defmodule FermixCore.Providers.OpenAIDefaultModelTest do
  @moduledoc """
  The legacy Chat Completions module resolves its model the way the route
  does, so nothing in the tree names an OpenAI model of its own.
  """
  use ExUnit.Case, async: false

  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.OpenAI

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    on_exit(fn -> restore(providers) end)
    :ok
  end

  test "default_model/0 is the catalog default while no model is configured" do
    Application.put_env(:fermix_core, :providers, [])
    assert OpenAI.default_model() == ModelCatalog.default_model_for(:openai)

    Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test"])
    assert OpenAI.default_model() == ModelCatalog.default_model_for(:openai)
  end

  test "default_model/0 is the configured model when one is named" do
    Application.put_env(:fermix_core, :providers, openai: [default_model: "gpt-5.4-mini"])
    assert OpenAI.default_model() == "gpt-5.4-mini"
  end

  defp restore(nil), do: Application.delete_env(:fermix_core, :providers)
  defp restore(value), do: Application.put_env(:fermix_core, :providers, value)
end
