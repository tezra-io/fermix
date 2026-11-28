defmodule FermixCore.Jobs.SignInConfirmTest do
  @moduledoc """
  The setting behind the question about a job that signs in to websites
  (`[fermix_core.jobs] confirm_sign_in_jobs`): read through the context's
  `:jobs_config` when a caller hands one in, and turned off by the owner's
  Always allow, which writes the home's `config.toml`. The write runs against
  a home of this test's own and restores every setting it applied, so the
  module is not async.
  """
  use ExUnit.Case, async: false

  alias FermixCore.Jobs.SignInConfirm
  alias FermixCore.Setup.ConfigStore

  describe "asks?/1" do
    test "asks unless the jobs config turns the question off" do
      assert SignInConfirm.asks?(%{jobs_config: []})
      assert SignInConfirm.asks?(%{jobs_config: [confirm_sign_in_jobs: true]})
      refute SignInConfirm.asks?(%{jobs_config: [confirm_sign_in_jobs: false]})
    end

    test "a value that is not a yes or a no fails loud" do
      assert_raise CaseClauseError, fn ->
        SignInConfirm.asks?(%{jobs_config: [confirm_sign_in_jobs: "no"]})
      end
    end
  end

  describe "stop_asking/1" do
    setup do
      core = Application.get_all_env(:fermix_core)
      channels = Application.get_all_env(:fermix_channels)
      web = Application.get_all_env(:fermix_web)
      previous_home = System.get_env("FERMIX_HOME")

      FermixTestSupport.SecretWriterStub.reset()
      Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)

      home = FermixTestSupport.SafeRm.make_tmp_dir!("sign-in-confirm-home")
      System.put_env("FERMIX_HOME", home)

      File.write!(Path.join(home, "config.toml"), """
      [fermix_core.jobs]
      default_delivery_mode = "origin"
      """)

      on_exit(fn ->
        case previous_home do
          nil -> System.delete_env("FERMIX_HOME")
          value -> System.put_env("FERMIX_HOME", value)
        end

        restore(:fermix_core, core)
        restore(:fermix_channels, channels)
        restore(:fermix_web, web)
        FermixTestSupport.SecretWriterStub.reset()
        FermixTestSupport.SafeRm.rm_rf!(home)
      end)

      %{home: home}
    end

    test "writes the question off, keeps the other jobs settings, and stops asking", %{
      home: home
    } do
      assert {:ok, before} = ConfigStore.load_runtime_config()
      refute Keyword.has_key?(Keyword.get(before.fermix_core, :jobs, []), :confirm_sign_in_jobs)

      assert :ok = SignInConfirm.stop_asking()

      contents = File.read!(Path.join(home, "config.toml"))
      assert contents =~ "confirm_sign_in_jobs = false"

      assert {:ok, loaded} = ConfigStore.load_runtime_config()
      jobs = Keyword.get(loaded.fermix_core, :jobs, [])
      assert Keyword.get(jobs, :confirm_sign_in_jobs) == false
      assert Keyword.get(jobs, :default_delivery_mode) == "origin"

      # Applied to what runs: the next set-up reads the setting off.
      refute SignInConfirm.asks?(%{})
    end
  end

  # Every key the save applied goes back to its value before the test, and a
  # key it added is removed.
  defp restore(app, previous) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(previous, key),
        do: Application.delete_env(app, key)

    Enum.each(previous, fn {key, value} -> Application.put_env(app, key, value) end)
  end
end
