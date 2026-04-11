defmodule Mix.Tasks.Fermix.SetupTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.ConfigStore

  setup do
    providers = Application.fetch_env(:fermix_core, :providers)
    telegram = Application.fetch_env(:fermix_channels, :telegram)
    fermix_home = System.get_env("FERMIX_HOME")
    shell = Mix.shell()

    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      restore_env(:fermix_channels, :telegram, telegram)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Mix.shell(shell)
    end)

    :ok
  end

  test "--print-state reports ready from persisted setup" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-setup-task-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)

    System.put_env("FERMIX_HOME", tmp_home)

    :ok =
      ConfigStore.save_snapshot(%{
        fermix_core: [providers: [openai: [auth_mode: :api_key, api_key: "sk-test-123"]]],
        fermix_channels: [telegram: [enabled: true, mode: :webhook, bot_token: "bot-token"]],
        fermix_web: []
      })

    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)

    Mix.Task.reenable("fermix.setup")
    Mix.Tasks.Fermix.Setup.run(["--print-state"])

    assert_received {:mix_shell, :info, ["status: ready"]}
    assert_received {:mix_shell, :info, ["All required setup checks are satisfied."]}
  end

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
