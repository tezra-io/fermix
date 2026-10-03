defmodule FermixCore.Setup.LiveModelTest do
  # Saves through the real settings path (config.toml in a temporary home, then
  # application environment), so it runs alone and restores what it touched.
  use ExUnit.Case, async: false

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.LiveModel
  alias FermixCore.Setup.Wizard
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @core_keys [
    :providers,
    :agent,
    :personalization,
    :sandbox,
    :tools,
    :realtime,
    :secret_writer
  ]
  @channel_keys [:telegram, :whatsapp, :discord, :slack, :signal, :acp, :mobile]

  setup do
    core = Map.new(@core_keys, &{&1, Application.fetch_env(:fermix_core, &1)})
    channels = Map.new(@channel_keys, &{&1, Application.fetch_env(:fermix_channels, &1)})
    home = System.get_env("FERMIX_HOME")
    tmp_home = SafeRm.make_tmp_dir!("live-model")

    System.put_env("FERMIX_HOME", tmp_home)
    SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, name: "fermix")

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(:fermix_core, key, value) end)
      Enum.each(channels, fn {key, value} -> restore(:fermix_channels, key, value) end)
      SecretWriterStub.reset()

      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(tmp_home)
    end)

    :ok
  end

  defp listing(slugs) do
    test_pid = self()

    fn provider, opts ->
      send(test_pid, {:listed, provider, opts})
      {:ok, Enum.map(slugs, &%{id: &1, label: String.upcase(&1), context_window: nil})}
    end
  end

  defp persisted_model do
    {:ok, snapshot} = ConfigStore.load_runtime_config(resolve_secrets: false)

    snapshot.fermix_core
    |> Keyword.get(:providers, [])
    |> Keyword.get(:openai_codex, [])
    |> Keyword.get(:default_model)
  end

  defp configure_model(model) do
    {:ok, _report} =
      Wizard.save_answers(Wizard.report().wizard,
        edit_provider: :openai_codex,
        default_model: model
      )
  end

  test "an empty default_model gets the FIRST listed slug, through the normal save path" do
    assert {:ok, %{model: "gpt-6.1-sol", changed?: true}} =
             LiveModel.ensure(:openai_codex,
               listing: listing(["gpt-6.1-sol", "gpt-6-luna"]),
               listing_opts: [access_token: "plan-token"]
             )

    assert_received {:listed, :openai_codex, [access_token: "plan-token"]}
    assert persisted_model() == "gpt-6.1-sol"

    assert Application.get_env(:fermix_core, :providers)[:openai_codex][:default_model] ==
             "gpt-6.1-sol"
  end

  test "a configured model the account lists is kept and nothing is written" do
    configure_model("gpt-6-luna")
    before = File.read!(ConfigStore.path())

    assert {:ok, %{model: "gpt-6-luna", changed?: false}} =
             LiveModel.ensure(:openai_codex, listing: listing(["gpt-6.1-sol", "gpt-6-luna"]))

    assert File.read!(ConfigStore.path()) == before
  end

  # The model a Codex-client sign-in ran on may not be one the ChatGPT plan
  # lists; the route would refuse it, so the first listed slug replaces it.
  test "a configured model the account does not list is replaced by the first listed one" do
    configure_model("gpt-5.4")

    assert {:ok, %{model: "gpt-6.1-sol", changed?: true}} =
             LiveModel.ensure(:openai_codex, listing: listing(["gpt-6.1-sol", "gpt-6-luna"]))

    assert persisted_model() == "gpt-6.1-sol"
  end

  test "an empty listing is refused with a sentence and nothing is written" do
    assert {:error, sentence} = LiveModel.ensure(:openai_codex, listing: listing([]))

    assert sentence == "OpenAI Codex is connected, but it listed no models for this account."
    refute File.exists?(ConfigStore.path())
  end

  test "a failed listing is refused with its reason and nothing is written" do
    failing = fn :openai_codex, _opts ->
      {:error, "HTTP 503 from https://api.openai.com/v1/models"}
    end

    assert {:error, sentence} = LiveModel.ensure(:openai_codex, listing: failing)

    assert sentence ==
             "OpenAI Codex is connected, but its models could not be listed: " <>
               "HTTP 503 from https://api.openai.com/v1/models"

    refute File.exists?(ConfigStore.path())
  end

  test "an unknown provider fails loud" do
    assert_raise ArgumentError, ~r/unknown provider :nope/, fn ->
      LiveModel.ensure(:nope, listing: listing(["x"]))
    end
  end

  defp restore(app, key, :error), do: Application.delete_env(app, key)
  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
