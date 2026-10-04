defmodule FermixCore.Management.IMessageTest do
  @moduledoc """
  `imessage.permissions.get`, `imessage.grant.start` and
  `imessage.policy.confirm` (M54 §12).

  The helper is never spawned here: the probe, the grant, the policy read and
  the confirmation are injected as sources, so what is under test is the view
  the daemon builds from them, the job each starts, and the sentence a person
  reads when one is refused.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Management.IMessage
  alias FermixCore.Management.Jobs

  @probe %{
    helper_version: "0.1.0",
    full_disk_access: :granted,
    db: :readable,
    automation: :not_determined,
    messages_running: true,
    signed_in: :unknown,
    user_session: true,
    policy: :confirmed,
    self_aliases: nil
  }

  @config [
    enabled: true,
    posture: :dedicated_account,
    owner_user_id: "+15551234567",
    allowed_sender_ids: ["friend@example.com"]
  ]

  @stored %{
    posture: :dedicated_account,
    owner_handle: "+15551234567",
    handles: ["+15551234567", "friend@example.com"],
    confirmed_at: "2026-10-01T10:00:00Z"
  }

  @view_keys ~w(installed helper_version full_disk_access db automation messages_running
                signed_in user_session policy policy_matches_config probed_at)

  setup context do
    tasks = :"imessage_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    server =
      start_supervised!(
        {Jobs, name: :"imessage_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    %{jobs: [server: server]}
  end

  describe "imessage.permissions.get" do
    test "a probed helper answers every field, as words the app switches on" do
      assert {:ok, view} = IMessage.permissions(sources())

      assert Enum.sort(Map.keys(view)) == Enum.sort(@view_keys)

      assert %{
               "installed" => true,
               "helper_version" => "0.1.0",
               "full_disk_access" => "granted",
               "db" => "readable",
               "automation" => "not_determined",
               "messages_running" => true,
               "signed_in" => nil,
               "user_session" => true,
               "policy" => "confirmed",
               "policy_matches_config" => true
             } = view

      assert is_binary(view["probed_at"])
    end

    test "a stored policy that names other recipients does not match the saved settings" do
      other = %{@stored | handles: ["+15551234567"]}

      assert {:ok, %{"policy_matches_config" => false}} =
               IMessage.permissions(sources(policy: fn -> {:ok, other} end))
    end

    test "an absent policy is not read and never matches" do
      probe = %{@probe | policy: :absent}

      assert {:ok, %{"policy" => "absent", "policy_matches_config" => false}} =
               IMessage.permissions(
                 sources(
                   probe: fn -> {:ok, probe} end,
                   policy: fn -> flunk("read a policy the probe says is absent") end
                 )
               )
    end

    test "a helper that is not installed answers installed false and nothing else" do
      assert {:ok, view} =
               IMessage.permissions(
                 sources(installed?: fn -> false end, probe: fn -> flunk("probed") end)
               )

      assert view["installed"] == false
      assert Enum.all?(@view_keys -- ["installed"], &(view[&1] == nil))
    end

    test "a probe that fails is unavailable, and its reason reaches the log" do
      log =
        capture_log(fn ->
          assert IMessage.permissions(
                   sources(probe: fn -> {:error, {:helper_exit, :disclaim_refused}} end)
                 ) == {:error, {:unavailable, "imessage_permissions"}}
        end)

      assert log =~ "disclaim_refused"
    end

    test "off a Mac the channel does not exist" do
      assert IMessage.permissions(sources(macos?: false)) ==
               {:error, {:unavailable, "imessage"}}
    end
  end

  describe "imessage.grant.start" do
    test "a grant runs as an imessage_grant job and finishes with the probe", %{jobs: jobs} do
      grant = fn :automation -> {:ok, %{@probe | automation: :granted, signed_in: true}} end

      assert {:ok, started} =
               IMessage.grant_start("automation", sources(jobs: jobs, grant: grant))

      assert started["kind"] == "imessage_grant"
      assert started["budget_ms"] == 120_000

      done = await(started, jobs)
      assert done["status"] == "completed"
      assert done["result"]["automation"] == "granted"
      assert done["result"]["signed_in"] == true
    end

    test "a service that is not one of the two is refused before anything starts", %{
      jobs: jobs
    } do
      assert {:error, {:invalid_params, "service", sentence}} =
               IMessage.grant_start("contacts", sources(jobs: jobs))

      assert sentence =~ "automation"
    end

    test "a helper that is not installed fails the job with a sentence", %{jobs: jobs} do
      grant = fn _service -> {:error, :not_installed} end

      assert {:ok, started} =
               IMessage.grant_start("full_disk_access", sources(jobs: jobs, grant: grant))

      assert %{"status" => "failed", "failure" => %{"code" => "unavailable", "sentence" => s}} =
               await(started, jobs)

      assert s =~ "Fermix Messages is not installed"
    end
  end

  describe "imessage.policy.confirm" do
    test "the saved recipients are confirmed and the job finishes with the probe", %{jobs: jobs} do
      parent = self()

      set = fn policy ->
        send(parent, {:policy_set, policy})
        {:ok, %{confirmed_at: "2026-10-01T10:00:00Z"}}
      end

      assert {:ok, started} = IMessage.policy_confirm(sources(jobs: jobs, policy_set: set))
      assert started["kind"] == "imessage_policy_confirm"
      assert started["budget_ms"] == 180_000

      done = await(started, jobs)
      assert done["status"] == "completed"
      assert done["result"]["outcome"] == "confirmed"
      assert done["result"]["policy_matches_config"] == true

      assert_receive {:policy_set,
                      %{
                        posture: :dedicated_account,
                        owner_handle: "+15551234567",
                        handles: ["+15551234567", "friend@example.com"]
                      }}
    end

    # Cancel on the helper's dialog is the owner's decision, so it is how the
    # job ends rather than how it fails.
    test "a refused dialog is an outcome, not a failure", %{jobs: jobs} do
      set = fn _policy -> {:error, {:helper_error, :policy_refused, "Cancelled"}} end

      assert {:ok, started} =
               IMessage.policy_confirm(
                 sources(jobs: jobs, policy_set: set, policy: fn -> {:ok, nil} end)
               )

      done = await(started, jobs)
      assert done["status"] == "completed"
      assert done["result"]["outcome"] == "policy_refused"
      assert done["result"]["policy_matches_config"] == false
    end

    test "no saved owner is refused with what to do first", %{jobs: jobs} do
      assert {:ok, started} =
               IMessage.policy_confirm(sources(jobs: jobs, config: [posture: :dedicated_account]))

      assert %{"status" => "failed", "failure" => %{"code" => "refused", "sentence" => s}} =
               await(started, jobs)

      assert s =~ "Apple ID or phone number"
    end

    test "an owner that is not this account's own handle is refused in its own words", %{
      jobs: jobs
    } do
      set = fn _policy -> {:error, {:helper_error, :owner_not_self, "not an alias"}} end

      assert {:ok, started} = IMessage.policy_confirm(sources(jobs: jobs, policy_set: set))

      assert %{"failure" => %{"code" => "refused", "sentence" => s}} = await(started, jobs)
      assert s =~ "not a handle of the Messages account on this Mac"
    end
  end

  defp sources(overrides \\ []) do
    Keyword.merge(
      [
        macos?: true,
        installed?: fn -> true end,
        config: @config,
        probe: fn -> {:ok, @probe} end,
        policy: fn -> {:ok, @stored} end
      ],
      overrides
    )
  end

  defp await(view, jobs), do: await(view["job_id"], jobs, 100)

  defp await(job_id, jobs, 0) do
    {:ok, view} = Jobs.get(job_id, jobs)
    flunk("job #{job_id} never finished: #{inspect(view)}")
  end

  defp await(job_id, jobs, attempts) do
    {:ok, view} = Jobs.get(job_id, jobs)

    if view["status"] == "running" do
      Process.sleep(10)
      await(job_id, jobs, attempts - 1)
    else
      view
    end
  end
end
