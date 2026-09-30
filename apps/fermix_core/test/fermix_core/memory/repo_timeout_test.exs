defmodule FermixCore.Memory.RepoTimeoutTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixTestSupport.StalledRepo

  setup do
    %{stalled: start_supervised!(StalledRepo)}
  end

  # The periodic workers' ticks opt in: a Repo stuck behind a long operation
  # skips their work until the next tick instead of exiting them, which under
  # the root supervisor's :rest_for_one restarted every later sibling.
  test "a caller that opts in gets an error when the Repo does not answer in time", ctx do
    assert Repo.next_scheduled_job(server: ctx.stalled, timeout: 50, on_timeout: :error) ==
             {:error, :repo_timeout}
  end

  test "every other caller still exits when the Repo does not answer in time", ctx do
    assert {:timeout, {GenServer, :call, _args}} =
             catch_exit(Repo.next_scheduled_job(server: ctx.stalled, timeout: 50))
  end

  test "the timeout is traced as :repo_call, naming the request, before the error returns", ctx do
    test_pid = self()
    handler = "repo-timeout-test-#{System.unique_integer([:positive])}"

    # The event fires in the calling process, so pinning the test pid keeps
    # another test's Repo timeout out of this assertion.
    :telemetry.attach(
      handler,
      [:fermix, :timeout, :expired],
      fn _event, measurements, meta, _config ->
        if self() == test_pid, do: send(test_pid, {:expired, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :repo_timeout} = Repo.next_scheduled_job(Repo.periodic_opts(ctx.stalled, 50))
    assert_receive {:expired, %{ms: 50}, %{name: :repo_call}}
  end

  test "periodic_opts/2 is the opt-in every periodic worker passes" do
    assert Repo.periodic_opts(:a_repo, 50) == [server: :a_repo, on_timeout: :error, timeout: 50]
    assert_raise FunctionClauseError, fn -> Repo.periodic_opts(:a_repo, 0) end
  end
end
