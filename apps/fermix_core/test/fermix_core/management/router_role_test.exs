defmodule FermixCore.Management.RouterRoleTest do
  # M75 D5: a device-role engine makes no provider call and touches no provider
  # session, so every management method that would is refused by name, in the
  # wire's existing `unavailable` shape with the refusal's sentence.
  use ExUnit.Case, async: true

  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router

  @device %{role: :device, primary: "aws i-0f3b1c"}
  @sentence "This engine runs in the device role; the primary is aws i-0f3b1c."

  defp route(method, params, opts) do
    Router.route(
      %{method: method, protocol_version: Protocol.protocol_version(), params: params},
      opts
    )
  end

  @refused [
    {"providers.probe.start", %{"provider" => "anthropic"}, "providers"},
    {"providers.models.list", %{"provider" => "anthropic", "live" => true}, "providers"},
    {"auth.start", %{"provider" => "openai_codex"}, "auth"},
    {"auth.import.start", %{"source" => "claude_code"}, "auth"},
    {"auth.logout", %{"provider" => "openai_codex"}, "auth"},
    {"plugins.disconnect", %{"name" => "github"}, "plugins"},
    {"meetings.signin.start", %{}, "meetings"},
    {"doctor.start", %{"scope" => "network"}, "doctor"},
    # Storing the Anthropic setup token is a sign-in and clearing it a sign-out,
    # refused before anything is stored or removed.
    {"secret.set", %{"id" => "anthropic_setup_token", "value" => "sk-ant-oat01-invented"},
     "secrets"},
    {"secret.clear", %{"id" => "anthropic_setup_token"}, "secrets"}
  ]

  for {method, params, capability} <- @refused do
    @method method
    @params params
    @capability capability

    test "#{method} is refused by name on a device" do
      assert route(@method, @params, engine_role: @device) ==
               {:error, :unavailable, %{"capability" => @capability, "sentence" => @sentence}}
    end
  end

  test "the catalog's model list calls no provider, so a device still answers it" do
    params = %{"provider" => "anthropic", "live" => false}

    assert {:ok, %{}} = route("providers.models.list", params, engine_role: @device)
  end

  test "the primary is not refused" do
    params = %{"provider" => "anthropic", "live" => false}

    assert {:ok, %{}} =
             route("providers.models.list", params, engine_role: %{role: :primary, primary: nil})
  end
end
