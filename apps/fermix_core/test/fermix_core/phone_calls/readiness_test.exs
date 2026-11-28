defmodule FermixCore.PhoneCalls.ReadinessTest do
  # `decide/1` is pure. `current/1` reads its inputs from the running engine
  # unless a test hands them in; every test here hands in all of them except
  # the one it proves is read from the real source, which it sets and restores,
  # so the module runs alone.
  use ExUnit.Case, async: false

  alias FermixCore.Net.Egress
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Readiness

  # Invented values, in the 555-01XX range NANPA reserves for fiction.
  @caller "+14155550142"

  defp ready_config(overrides \\ []) do
    struct!(
      Config.normalize(
        enabled: true,
        caller_number: @caller,
        sip_username: "fermixtrunk01",
        sip_password: "invented-trunk-password"
      ),
      overrides
    )
  end

  defp inputs(overrides \\ %{}) do
    Map.merge(
      %{
        config: ready_config(),
        openai_api_key?: true,
        openai_api_key_unsendable?: false,
        sip_password?: true,
        primary?: true,
        durable_memory?: true,
        control_route?: true,
        call_backend?: true
      },
      overrides
    )
  end

  describe "decide/1" do
    test "everything in place is ready" do
      assert Readiness.decide(inputs()) == :ready
    end

    test "a disabled section is disabled, whatever else is missing" do
      assert Readiness.decide(
               inputs(%{
                 config: ready_config(enabled: false),
                 openai_api_key?: false,
                 primary?: false
               })
             ) == :disabled
    end

    test "each missing requirement is its own reason" do
      for {override, reason} <- [
            {%{primary?: false}, :not_primary},
            {%{durable_memory?: false}, :durable_memory_off},
            {%{openai_api_key?: false}, :openai_api_key_missing},
            {%{config: ready_config(caller_number: nil)}, :caller_number_missing},
            {%{config: ready_config(sip_username: nil)}, :sip_username_missing},
            {%{sip_password?: false}, :sip_password_missing},
            {%{control_route?: false}, :egress_proxy_unsupported},
            {%{call_backend?: false}, :call_backend_missing}
          ] do
        assert Readiness.decide(inputs(override)) == {:needs_setup, [reason]}, inspect(reason)
      end
    end

    # A key that is missing cannot also be one that cannot be sent, so every
    # reason but that one can be listed at once.
    test "every missing requirement is listed, in a fixed order" do
      assert Readiness.decide(
               inputs(%{
                 config: ready_config(caller_number: nil, sip_username: nil),
                 openai_api_key?: false,
                 openai_api_key_unsendable?: true,
                 sip_password?: false,
                 primary?: false,
                 durable_memory?: false,
                 control_route?: false,
                 call_backend?: false
               })
             ) == {:needs_setup, Readiness.reasons() -- [:openai_api_key_unsendable]}
    end

    test "a stored key no request could carry is its own reason, after the key's presence" do
      assert Readiness.decide(inputs(%{openai_api_key_unsendable?: true})) ==
               {:needs_setup, [:openai_api_key_unsendable]}

      assert Readiness.decide(inputs(%{openai_api_key?: false, openai_api_key_unsendable?: true})) ==
               {:needs_setup, [:openai_api_key_missing]}

      assert Readiness.sentence(:openai_api_key_unsendable) =~ "OpenAI API key"
      assert Readiness.sentence(:openai_api_key_unsendable) =~ "again"
    end

    test "each reason has one owner-readable sentence of its own" do
      sentences = Enum.map(Readiness.reasons(), &Readiness.sentence/1)

      assert Enum.all?(sentences, &(is_binary(&1) and String.ends_with?(&1, ".")))
      assert sentences == Enum.uniq(sentences)
      assert Readiness.sentence(:openai_api_key_missing) =~ "OpenAI"
    end
  end

  describe "current/1" do
    # The backend a call's turns run on is the one the composition root wires
    # (`Delegate.configured/0`): none configured, as in this test build, is
    # its own reason; a module that implements the behaviour is ready.
    test "takes the call backend from the configured delegate" do
      opts = inputs() |> Map.delete(:call_backend?) |> Map.to_list()
      saved = Application.fetch_env(:fermix_core, :phone_calls_delegate)

      on_exit(fn ->
        case saved do
          {:ok, value} -> Application.put_env(:fermix_core, :phone_calls_delegate, value)
          :error -> Application.delete_env(:fermix_core, :phone_calls_delegate)
        end
      end)

      Application.put_env(:fermix_core, :phone_calls_delegate, nil)
      assert Readiness.current(opts) == {:needs_setup, [:call_backend_missing]}

      Application.put_env(:fermix_core, :phone_calls_delegate, String)
      assert Readiness.current(opts) == {:needs_setup, [:call_backend_missing]}

      Application.put_env(
        :fermix_core,
        :phone_calls_delegate,
        FermixTestSupport.PhoneCallFakes.Delegate
      )

      assert Readiness.current(opts) == :ready
    end

    test "decides over the inputs it is handed" do
      assert Readiness.current(Map.to_list(inputs())) == :ready

      assert Readiness.current(Map.to_list(inputs(%{durable_memory?: false}))) ==
               {:needs_setup, [:durable_memory_off]}
    end

    test "takes the trunk password's presence from the config it reads" do
      opts = inputs() |> Map.delete(:sip_password?) |> Map.to_list()

      assert Readiness.current(opts) == :ready

      unresolved = Keyword.put(opts, :config, ready_config(sip_password: "@keyring"))
      assert Readiness.current(unresolved) == {:needs_setup, [:sip_password_missing]}
    end

    # The create's own test (`OpenAILive.control_route/1`): the sideband is a
    # WebSocket, which the proxy cannot carry, so a proxy that would carry
    # OpenAI's origin is a reason, and one it bypasses is not.
    test "takes the control route from the egress the call's create would use" do
      opts = inputs() |> Map.delete(:control_route?) |> Map.to_list()
      proxy = "http://proxy.invented.test:3128"

      assert Readiness.current([{:egress, Egress.new(proxy: proxy)} | opts]) ==
               {:needs_setup, [:egress_proxy_unsupported]}

      bypassed = Egress.new(proxy: proxy, proxy_bypass: ["api.openai.com"])
      assert Readiness.current([{:egress, bypassed} | opts]) == :ready
      assert Readiness.current([{:egress, Egress.new([])} | opts]) == :ready
    end

    test "a SpaceXAI key never satisfies the OpenAI key the phone engine needs" do
      providers = Application.fetch_env(:fermix_core, :providers)
      on_exit(fn -> restore(:providers, providers) end)

      Application.put_env(:fermix_core, :providers, xai: [api_key: "xai-invented"])
      opts = inputs() |> Map.delete(:openai_api_key?) |> Map.to_list()

      assert Readiness.current(opts) == {:needs_setup, [:openai_api_key_missing]}

      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-invented"],
        xai: [api_key: "xai-invented"]
      )

      assert Readiness.current(opts) == :ready
    end

    # The transport's own rule (`OpenAILive.sendable_api_key?/1`): a bearer
    # token is printable ASCII with no space, so a key saved with a trailing
    # line break is found here, not when a call ends `create_not_sent`.
    test "a stored OpenAI key the transport would refuse is found before any call" do
      providers = Application.fetch_env(:fermix_core, :providers)
      on_exit(fn -> restore(:providers, providers) end)

      opts =
        inputs()
        |> Map.drop([:openai_api_key?, :openai_api_key_unsendable?])
        |> Map.to_list()

      for key <- ["sk-invented\n", "sk-invented ", "sk invented", "sk-\tinvented", "sk-invénted"] do
        Application.put_env(:fermix_core, :providers, openai: [api_key: key])

        assert Readiness.current(opts) == {:needs_setup, [:openai_api_key_unsendable]},
               inspect(key)
      end

      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-proj-Invented_0123-xyz"]
      )

      assert Readiness.current(opts) == :ready

      Application.put_env(:fermix_core, :providers, openai: [api_key: "@keyring"])
      assert Readiness.current(opts) == {:needs_setup, [:openai_api_key_missing]}
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:fermix_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:fermix_core, key)
end
