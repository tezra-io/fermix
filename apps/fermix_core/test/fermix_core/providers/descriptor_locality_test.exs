defmodule FermixCore.Providers.DescriptorLocalityTest do
  @moduledoc """
  MILESTONE_32 §9.3 — provider locality is declared, never inferred. Every
  descriptor must carry a `:locality`, Ollama is the only local one, and the
  fail-closed accessor treats an unknown provider as remote.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Providers.Descriptor

  test "all/0 materializes every descriptor with a declared locality" do
    # struct!/2 enforces @enforce_keys at materialization, so a descriptor
    # missing :locality would raise here — that is the "declared" enforcement.
    for descriptor <- Descriptor.all() do
      assert descriptor.locality in [:local_loopback, :remote],
             "#{descriptor.id} has no valid locality"
    end
  end

  test "Ollama is the only local-loopback provider; every hosted provider is remote" do
    assert Descriptor.fetch!(:ollama).locality == :local_loopback

    for descriptor <- Descriptor.all(), descriptor.id != :ollama do
      assert descriptor.locality == :remote,
             "expected #{descriptor.id} to be :remote"
    end
  end

  test "locality/1 reads the declared value and fails closed on an unknown id" do
    assert Descriptor.locality(:ollama) == :local_loopback
    assert Descriptor.locality(:anthropic) == :remote
    assert Descriptor.locality(:openai) == :remote
    # Unknown ⇒ remote: a route the Gate cannot classify is never local.
    assert Descriptor.locality(:does_not_exist) == :remote
  end
end
