defmodule FermixCore.Providers.DescriptorTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.ReasoningEffort
  alias FermixCore.Setup.SecretPaths

  # Order is load-bearing: fallback order + auto-promotion tie-break.
  test "ids/0 returns the canonical ordered provider list" do
    assert Descriptor.ids() == [
             :openai_codex,
             :openai,
             :anthropic,
             :xai,
             :openrouter,
             :mistral,
             :ollama
           ]
  end

  test "ModelCatalog.providers/0 delegates to the registry" do
    assert ModelCatalog.providers() == Descriptor.ids()
  end

  test "fetch/1 returns :error for unknown providers; fetch!/1 raises" do
    assert Descriptor.fetch(:nonexistent) == :error

    assert_raise ArgumentError, ~r/unknown provider :nonexistent/, fn ->
      Descriptor.fetch!(:nonexistent)
    end
  end

  test "every descriptor id has catalog models with a default" do
    for id <- Descriptor.ids() do
      assert [_ | _] = ModelCatalog.models_for(id)
      assert is_binary(ModelCatalog.default_model_for(id))
    end
  end

  test "every descriptor secret exists in the SecretPaths registry" do
    for descriptor <- Descriptor.all(), secret <- descriptor.secrets do
      assert %{key: ^secret} = SecretPaths.fetch!(secret)
    end
  end

  test "secrets equal the secret? subset of setup_fields" do
    for descriptor <- Descriptor.all() do
      field_secrets =
        for field <- descriptor.setup_fields, field.secret?, do: field.key

      assert Enum.sort(descriptor.secrets) == Enum.sort(field_secrets),
             "#{descriptor.id}: secrets #{inspect(descriptor.secrets)} != " <>
               "secret setup_fields #{inspect(field_secrets)}"
    end
  end

  test "effort? flag matches the ReasoningEffort provider-levels table" do
    for descriptor <- Descriptor.all() do
      assert descriptor.effort? == (ReasoningEffort.levels_for(descriptor.id) != []),
             "#{descriptor.id}: effort? #{descriptor.effort?} disagrees with @provider_levels"
    end
  end

  test "auth modes are valid and single-or-multi as declared" do
    for descriptor <- Descriptor.all() do
      assert descriptor.auth_modes != []
      assert Enum.all?(descriptor.auth_modes, &(&1 in [:api_key, :oauth, :none]))

      assert Descriptor.default_auth_mode(descriptor) == hd(descriptor.auth_modes)
      assert Descriptor.multi_auth_mode?(descriptor) == length(descriptor.auth_modes) > 1
    end
  end

  test "setup_fields config keys are inside the block's config_keys allowlist" do
    for descriptor <- Descriptor.all(), field <- descriptor.setup_fields do
      assert field.config_key in descriptor.config_keys,
             "#{descriptor.id}: setup field #{field.key} writes #{inspect(field.config_key)} " <>
               "which is outside config_keys"
    end
  end

  test "adapter is a module or :routed" do
    for descriptor <- Descriptor.all() do
      assert descriptor.adapter == :routed or is_atom(descriptor.adapter)

      if descriptor.adapter != :routed do
        assert Code.ensure_loaded?(descriptor.adapter),
               "#{descriptor.id}: adapter #{inspect(descriptor.adapter)} does not exist"
      end
    end
  end
end
