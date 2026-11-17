defmodule FermixCore.PhoneCalls.GrantsTest do
  # What a brief may grant a phone call's backend turn (M94 §06, §11), held
  # over every built-in Fermix can seed, not over a hand-written list.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.PhoneCalls.Grants
  alias FermixCore.PhoneCalls.Tools, as: PhoneCallTools
  alias FermixCore.Tools.PhoneCall
  alias FermixCore.Tools.PhoneCallEnd
  alias FermixCore.Tools.PhoneCallPressKeys

  test "the grantable tools resolve, in their order, repeats dropped" do
    assert Grants.resolve([]) == {:ok, []}

    assert Grants.resolve(["place_search", "web_search", "place_search"]) ==
             {:ok, ["place_search", "web_search"]}
  end

  test "a refusal names every rejected tool and why" do
    assert Grants.resolve(["web_search", "phone_call", "phone_call_end", "shell", "web_fetch"]) ==
             {:error,
              {:tools_not_grantable,
               [
                 {"phone_call", :places_calls},
                 {"phone_call_end", :call_control},
                 {"shell", :not_grantable},
                 {"web_fetch", :not_grantable}
               ]}}
  end

  test "of every built-in, only the grantable ones resolve" do
    modules = BuiltinSeeder.builtin_tool_modules() ++ PhoneCallTools.modules()

    for module <- modules do
      name = module.name()
      resolved = Grants.resolve([name])

      if name in Grants.grantable(),
        do: assert(resolved == {:ok, [name]}),
        else: assert({:error, {:tools_not_grantable, [{^name, _why}]}} = resolved)
    end
  end

  # The rule a grant is held to, over the capability each grantable built-in
  # actually builds: a read of public information, nothing else.
  test "every grantable tool reads public information and does nothing else" do
    by_name = Map.new(BuiltinSeeder.builtin_tool_modules(), &{&1.name(), &1})

    for name <- Grants.grantable() do
      capability = by_name |> Map.fetch!(name) |> Builtin.from_tool_module()

      assert capability.kind == :builtin
      assert capability.policy_class in [:read_only, :network]
      refute capability.owner_only?
      refute capability.hidden_from_agent?
      refute Map.get(capability.metadata, :host_command?, false)
      refute Map.get(capability.metadata, :access_sensitive?, false)
      refute Map.get(capability.metadata, :plugin_owned?, false)
      assert capability.metadata.category == :web
    end
  end

  test "the feature's tools: the call itself, then its keypad and hang-up" do
    assert PhoneCallTools.modules() == [PhoneCall, PhoneCallPressKeys, PhoneCallEnd]
    assert PhoneCallTools.control_names() == ["phone_call_press_keys", "phone_call_end"]
  end

  test "a grant that is not a tool name is a defect and raises" do
    assert_raise ArgumentError, fn -> Grants.resolve([:web_search]) end
  end
end
