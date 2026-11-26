defmodule FermixCore.Jobs.HealCardTest do
  # M106 §5.7 and decision D5 (stage S4b): a heal's proposal is answered on
  # its card, through the answer rail a watcher's card uses (`Cues.Proposals`,
  # its third holder), by its token or a bare answer, only from the chat and
  # the user it was sent to, with no model between the answer and the change.
  # The rail and the heal's own answer (`Jobs.HealAnswer`) run with the cues
  # feature off, as it is by default: Auto Heal is on for every home. A
  # heal's card is never one of the watcher proposals the apps list. Every
  # value is invented; every time is given.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues
  alias FermixCore.Cues.Proposals
  alias FermixCore.Jobs.Registry
  alias FermixCore.Management.Cues, as: ManagementCues
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.GetJobRun
  alias FermixCore.Tools.ListJobs
  alias FermixTestSupport.HealCards
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @heal_event [:fermix, :job, :heal]
  @owner %{platform: "telegram", chat_id: "40017", user_id: "40017"}
  @wrong_chat "Answer it from the chat Fermix sent it to; nothing was changed."
  @no_always "Only a follow-up's card offers Always allow; nothing ran."

  # `SkillRegistry.load/2`'s one call, over no skills.
  defmodule NoSkills do
    @moduledoc false

    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:load, name}, _from, state),
      do: {:reply, {:error, {:unknown_skill, name}}, state}
  end

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("heal-card")
    repo = :"heal_card_repo_#{unique}"
    caps = :"heal_card_caps_#{unique}"
    skills = :"heal_card_skills_#{unique}"

    db_path = Path.join(dir, "memory.db")
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({CapabilityRegistry, name: caps})
    start_supervised!({NoSkills, skills})
    on_exit(fn -> SafeRm.rm_rf!(dir) end)

    # The default: the cues feature is off and its tree is not running.
    refute Cues.enabled?()
    refute Cues.running?()

    now = DateTime.add(HealCards.delivered_at(), 600, :second)

    opts = [
      repo: repo,
      now: now,
      scheduler: nil,
      capability_registry: caps,
      skill_registry: skills
    ]

    %{repo: repo, db_path: db_path, opts: opts, now: now}
  end

  describe "a yes" do
    test "by its token from the chat it went to makes exactly the recorded change, once", ctx do
      TelemetryCapture.attach([@heal_event], :emitter)
      %{job: job, heal: heal, token: token} = HealCards.waiting_card!(ctx.repo, @owner)

      assert {:ok, sentence} = Proposals.confirm(token, @owner, ctx.opts)
      assert sentence =~ ~s(Fermix made the change it proposed to job "#{job.name}")

      assert {:ok, %{schedule_expr: "every 2 hours"} = changed} = get_job(ctx, job.id)
      assert Map.drop(changed, changed_keys()) == Map.drop(job, changed_keys())

      assert {:ok, %{state: "watching", answer: "apply", decided_from: "telegram:40017:40017"}} =
               get_heal(ctx, heal.id)

      assert_received {:telemetry, @heal_event, _,
                       %{phase: "answered", applied: true, platform: "telegram"}}

      assert {:error, again} = Proposals.confirm(token, @owner, ctx.opts)

      assert again ==
               ~s(Fermix already made this change to job "#{job.name}"; nothing more was changed.)

      assert {:ok, ^changed} = get_job(ctx, job.id)
    end

    test "after the job was edited is refused, and says the proposal is closed", ctx do
      %{job: job, heal: heal, token: token} = HealCards.waiting_card!(ctx.repo, @owner)

      {:ok, _edited} =
        Registry.update_job(job.id, %{task_prompt: "Read the tide board."},
          repo: ctx.repo,
          scheduler: nil,
          now: ctx.now
        )

      assert {:error, sentence} = Proposals.confirm(token, @owner, ctx.opts)

      assert sentence ==
               ~s(Nothing was applied: job "#{job.name}" is no longer the version Fermix drew ) <>
                 "this change for, so the proposal is closed."

      assert {:ok, %{schedule_expr: "every 1 hour"}} = get_job(ctx, job.id)
      assert {:ok, %{state: "closed", outcome: "superseded"}} = get_heal(ctx, heal.id)
    end
  end

  describe "a no" do
    test "closes the heal skipped, leaves the job, and the same failure is quiet", ctx do
      %{job: job, heal: heal, token: token} = HealCards.waiting_card!(ctx.repo, @owner)

      assert {:ok, sentence} = Proposals.deny(token, @owner, ctx.opts)
      assert sentence =~ ~s(Job "#{job.name}" is left as it is)
      assert {:ok, ^job} = get_job(ctx, job.id)

      assert {:ok, %{state: "closed", outcome: "skipped", decided_from: "telegram:40017:40017"}} =
               get_heal(ctx, heal.id)

      three_days_on = DateTime.add(ctx.now, 3 * 86_400, :second)
      assert {:ok, {_run, _job, %{heal: :quiet}}} = HealCards.fail!(ctx.repo, job, three_days_on)

      # `list_jobs` reads what became of it, and nothing of the chat it came from.
      {:ok, %{success: true, output: output}} =
        ListJobs.execute(%{}, %{memory_repo: ctx.repo, now_fn: fn -> three_days_on end})

      listed = output |> Jason.decode!() |> Map.fetch!("jobs") |> Enum.find(&(&1["id"] == job.id))
      assert %{"outcome" => "skipped", "answer" => "leave"} = listed["last_proposal"]
      refute output =~ "40017"
    end
  end

  describe "where an answer may come from" do
    test "another chat, another user or another platform is refused and changes nothing", ctx do
      %{job: job, heal: heal, token: token} = HealCards.waiting_card!(ctx.repo, @owner)

      for origin <- [
            %{@owner | chat_id: "-100777"},
            %{@owner | user_id: "51002"},
            %{@owner | platform: "signal"}
          ] do
        assert {:error, @wrong_chat} = Proposals.confirm(token, origin, ctx.opts)
        assert {:error, @wrong_chat} = Proposals.deny(token, origin, ctx.opts)
      end

      assert {:ok, ^job} = get_job(ctx, job.id)
      assert {:ok, %{state: "waiting", answer: nil}} = get_heal(ctx, heal.id)

      assert {:ok, _sentence} = Proposals.confirm(token, @owner, ctx.opts)
    end

    test "a bare answer finds the card in its own chat only, and its id answers only there",
         ctx do
      %{job: job, heal: heal} = HealCards.waiting_card!(ctx.repo, @owner)
      elsewhere = %{@owner | chat_id: "-100777"}

      assert {:ok, [waiting]} = Proposals.waiting_in_chat(@owner, ctx.opts)
      assert waiting == %{kind: :job_heal, id: heal.id, title: ~s(Change job "#{job.name}"?)}
      assert {:ok, []} = Proposals.waiting_in_chat(elsewhere, ctx.opts)

      assert {:error, "That card is not waiting in this chat; nothing ran."} =
               Proposals.confirm(heal.id, elsewhere, ctx.opts)

      assert {:ok, _sentence} = Proposals.confirm(heal.id, @owner, ctx.opts)
      assert {:ok, %{schedule_expr: "every 2 hours"}} = get_job(ctx, job.id)
      assert {:ok, []} = Proposals.waiting_in_chat(@owner, ctx.opts)
    end

    test "a card whose send never landed is no bare answer's, but its token still answers",
         ctx do
      %{heal: heal, token: token} = HealCards.waiting_card!(ctx.repo, @owner, delivered: false)
      {:ok, held} = Repo.job_heals_call({:get, heal.id}, server: ctx.repo)

      :ok =
        Repo.job_heals_call(
          {:dead_letter, heal.id, held.lease_token, %{attempts: 20, error: "gone"}, ctx.now},
          server: ctx.repo
        )

      assert {:ok, []} = Proposals.waiting_in_chat(@owner, ctx.opts)
      assert {:ok, _sentence} = Proposals.deny(token, @owner, ctx.opts)
    end
  end

  describe "a proposal that ended another way" do
    test "expired: a later answer says so and changes nothing", ctx do
      %{job: job, token: token} = HealCards.waiting_card!(ctx.repo, @owner)
      eight_days_on = DateTime.add(ctx.now, 8 * 86_400, :second)
      {:ok, [_expired]} = Repo.job_heals_call({:expire_waiting, eight_days_on}, server: ctx.repo)

      assert {:error, sentence} = Proposals.confirm(token, @owner, ctx.opts)

      assert sentence ==
               ~s(The change Fermix proposed for job "#{job.name}" expired after seven days ) <>
                 "without an answer; nothing was changed."

      assert {:ok, []} = Proposals.waiting_in_chat(@owner, ctx.opts)
    end

    test "the job recovered: a later answer says so and changes nothing", ctx do
      %{job: job, token: token} = HealCards.waiting_card!(ctx.repo, @owner)
      {:ok, {_run, _job, %{healed: [_id]}}} = HealCards.settle_ok!(ctx.repo, job, ctx.now)

      assert {:error, sentence} = Proposals.deny(token, @owner, ctx.opts)
      assert sentence =~ ~s(Job "#{job.name}" ran cleanly after Fermix proposed this)
      assert {:ok, %{schedule_expr: "every 1 hour"}} = get_job(ctx, job.id)
    end
  end

  test "/always takes nothing from a heal's card, which still waits", ctx do
    %{heal: heal, token: token} = HealCards.waiting_card!(ctx.repo, @owner)

    assert {:error, @no_always} = Proposals.always_allow(token, @owner, ctx.opts)
    assert {:error, @no_always} = Proposals.always_allow(heal.id, @owner, ctx.opts)
    assert {:ok, %{state: "waiting", answer: nil}} = get_heal(ctx, heal.id)
  end

  describe "the card's token" do
    test "is never in a read handed to a tool, a trace or a log, and goes at the send's end",
         ctx do
      TelemetryCapture.attach([@heal_event], :emitter)

      %{job: job, heal: heal, token: token} =
        HealCards.waiting_card!(ctx.repo, @owner, delivered: false)

      # Held while the send is pending, and only there.
      assert stored_token(ctx, heal.id) == token
      {:ok, pending} = Repo.job_heals_call({:get, heal.id}, server: ctx.repo)
      refute Map.has_key?(pending, :card_token)
      refute inspect(pending) =~ token

      {:ok, %{success: true, output: listed}} =
        ListJobs.execute(%{}, %{memory_repo: ctx.repo, now_fn: fn -> ctx.now end})

      refute listed =~ token

      {:ok, %{success: true, output: run}} =
        GetJobRun.execute(%{"run_id" => heal.last_run_id}, %{memory_repo: ctx.repo})

      refute run =~ token
      {:ok, [open]} = Repo.job_heals_call(:open_heals, server: ctx.repo)
      refute inspect(open) =~ token

      :ok =
        Repo.job_heals_call({:delivered, heal.id, pending.lease_token, ctx.now}, server: ctx.repo)

      assert stored_token(ctx, heal.id) == nil
      assert {:ok, _sentence} = Proposals.confirm(token, @owner, ctx.opts)

      for {:telemetry, @heal_event, _measurements, metadata} <- drain() do
        refute inspect(metadata) =~ token
      end

      assert {:ok, %{schedule_expr: "every 2 hours"}} = get_job(ctx, job.id)
    end

    test "a heal closed while its send was pending lets go of it", ctx do
      %{job: job, heal: heal} = HealCards.waiting_card!(ctx.repo, @owner, delivered: false)
      {:ok, {_run, _job, %{healed: [_id]}}} = HealCards.settle_ok!(ctx.repo, job, ctx.now)

      assert stored_token(ctx, heal.id) == nil
    end
  end

  describe "the apps' proposal family" do
    test "a waiting heal card is no watcher proposal: not offered, listed or counted", ctx do
      %{heal: heal} = HealCards.waiting_card!(ctx.repo, @owner)

      assert {:ok, []} = Proposals.waiting_cards(ctx.opts)
      assert {:ok, []} = Proposals.records(:waiting, ctx.opts)
      assert {:ok, []} = Proposals.records(:recent, ctx.opts)
      assert {:error, _not_found} = Proposals.card(heal.id, ctx.opts)

      for state <- [:waiting, :recent] do
        assert {:ok, %{"proposals" => [], "waiting" => 0}} =
                 ManagementCues.proposals_list(state, repo: ctx.repo, memory?: true)
      end
    end

    test "an app's answer by id is no answer to a heal's card", ctx do
      %{heal: heal} = HealCards.waiting_card!(ctx.repo, @owner)

      assert {:error, _sentence} =
               Proposals.decide(
                 heal.id,
                 :confirm,
                 %{surface: :companion, device_id: nil},
                 ctx.opts
               )

      assert {:ok, %{state: "waiting", answer: nil}} = get_heal(ctx, heal.id)
    end
  end

  # --- helpers -------------------------------------------------------------------

  defp changed_keys, do: [:schedule_expr, :next_run_at, :updated_at]

  defp get_job(ctx, id), do: Repo.get_scheduled_job(id, server: ctx.repo)
  defp get_heal(ctx, id), do: Repo.job_heals_call({:get, id}, server: ctx.repo)

  # The token column read directly, as only the bind reads it.
  defp stored_token(ctx, heal_id) do
    {:ok, conn} = Exqlite.Sqlite3.open(ctx.db_path, mode: :readonly)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT card_token FROM job_heals WHERE id = ?")
      :ok = Exqlite.Sqlite3.bind(stmt, [heal_id])
      {:row, [token]} = Exqlite.Sqlite3.step(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)
      token
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp drain(acc \\ []) do
    receive do
      {:telemetry, _event, _measurements, _metadata} = message -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
