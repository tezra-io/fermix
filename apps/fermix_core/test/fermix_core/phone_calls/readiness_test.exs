defmodule FermixCore.PhoneCalls.ReadinessTest do
  # `decide/1` is pure. `current/1` reads its inputs from the running engine
  # unless a test hands them in; every test here hands in all of them except
  # the one it proves is read from the real source, which it sets and restores,
  # so the module runs alone.
  use ExUnit.Case, async: false

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
        sip_password?: true,
        primary?: true,
        durable_memory?: true
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
            {%{sip_password?: false}, :sip_password_missing}
          ] do
        assert Readiness.decide(inputs(override)) == {:needs_setup, [reason]}, inspect(reason)
      end
    end

    test "every missing requirement is listed, in a fixed order" do
      assert Readiness.decide(
               inputs(%{
                 config: ready_config(caller_number: nil, sip_username: nil),
                 openai_api_key?: false,
                 sip_password?: false,
                 primary?: false,
                 durable_memory?: false
               })
             ) == {:needs_setup, Readiness.reasons()}
    end

    test "each reason has one owner-readable sentence of its own" do
      sentences = Enum.map(Readiness.reasons(), &Readiness.sentence/1)

      assert Enum.all?(sentences, &(is_binary(&1) and String.ends_with?(&1, ".")))
      assert sentences == Enum.uniq(sentences)
      assert Readiness.sentence(:openai_api_key_missing) =~ "OpenAI"
    end
  end

  describe "current/1" do
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
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:fermix_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:fermix_core, key)
end
