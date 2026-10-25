defmodule FermixCore.Cues.PinsTest do
  @moduledoc """
  The owner's approval of a mandate and its pin (M60 §10.4): approval records a
  digest of the mandate, the task, its skill and its validator; a change the
  digest covers, or `update_job` on the job, disables the mandate until it is
  approved again.
  """
  # The `update_job` case reads `[fermix_core.cues]` from the application
  # environment, a VM-global this module sets and restores.
  use ExUnit.Case, async: false

  import FermixTestSupport.CueFixtures, only: [exec!: 3]

  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Pins
  alias FermixCore.Tools.UpdateJob
  alias FermixTestSupport.MandateFixtures, as: F
  alias FermixTestSupport.SafeRm

  @name "release-issues"

  setup do
    fixture = F.cue_run("pins")
    config = F.config(@name, fixture.job.id)
    seams = Keyword.put(F.default_seams(fixture), :config, config)
    %{fixture: fixture, seams: seams}
  end

  test "an unknown or inactive mandate is not approved, with the reason", ctx do
    assert {:error, "No mandate is named nothing."} =
             Pins.approve("nothing", "test", F.now(), ctx.seams)

    inactive =
      Keyword.put(ctx.seams, :config, F.config(@name, ctx.fixture.job.id, %{"pin_args" => %{}}))

    assert {:error, sentence} = Pins.approve(@name, "test", F.now(), inactive)
    assert sentence =~ "Auto mode needs a validator or pinned arguments"
    assert {:ok, %{state: :unapproved}} = Pins.status(@name, ctx.seams)
  end

  test "approval, a changed validator, a disable and a new approval, as the setup page reads them",
       ctx do
    dir = SafeRm.make_tmp_dir!("pins-validator")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    validator = Path.join(dir, "validate.sh")
    File.write!(validator, "#!/bin/sh\necho '{\"allow\": true}'\n")

    seams =
      Keyword.put(
        ctx.seams,
        :config,
        F.config(@name, ctx.fixture.job.id, %{"validator" => validator})
      )

    assert {:ok, %{state: :unapproved, approved_at: nil}} = Pins.status(@name, seams)

    assert {:ok, %{state: :approved, approved_from: "setup page", approved_at: approved_at}} =
             Pins.approve(@name, "setup page", F.now(), seams)

    assert approved_at == F.now()
    assert {:ok, %{state: :approved}} = Pins.status(@name, seams)

    File.write!(validator, "#!/bin/sh\necho '{\"allow\": true, \"note\": \"wider\"}'\n")
    assert {:ok, %{state: :changed}} = Pins.status(@name, seams)

    assert {:ok, :disabled} =
             Pins.disable(@name, "the task changed since the mandate was granted", F.now(), seams)

    owner = F.owner_id()
    assert_received {:sent, ^owner, "Mandate release-issues is disabled" <> _, _opts}

    assert {:ok, :already_disabled} = Pins.disable(@name, "again", F.now(), seams)
    refute_received {:sent, _owner, _text, _opts}

    assert {:ok,
            %{state: :disabled, disabled_reason: "the task changed since the mandate was granted"}} =
             Pins.status(@name, seams)

    assert {:ok, %{state: :approved, disabled_at: nil}} =
             Pins.approve(@name, "setup page", F.now(), seams)
  end

  test "a job row that cannot be read leaves the pins unverified; a missing validator is unreadable",
       ctx do
    {:ok, mandate} = Mandates.get(@name, ctx.seams)
    {:ok, digest} = Pins.digest(mandate, ctx.seams)
    row = %{digest: digest}
    assert :ok = Pins.check(mandate, row, ctx.seams)

    busy = Keyword.put(ctx.seams, :get_job, fn _id -> {:error, :timeout} end)
    assert {:error, {:unverified, sentence}} = Pins.check(mandate, row, busy)
    assert sentence =~ "cannot be read"

    gone = %{mandate | validator: "/nonexistent/fermix/validate.py"}
    assert {:error, {:unreadable, sentence}} = Pins.check(gone, row, ctx.seams)
    assert sentence =~ "The validator /nonexistent/fermix/validate.py cannot be read"
  end

  test "the digest covers the task, its tools and route pin, not the mandate's switch", ctx do
    {:ok, mandate} = Mandates.get(@name, ctx.seams)
    {:ok, digest} = Pins.digest(mandate, ctx.seams)

    assert {:ok, ^digest} = Pins.digest(%{mandate | enabled?: false}, ctx.seams)

    for {column, value} <- [
          {"allowed_tools_json", ~s(["file_read"])},
          {"provider", "anthropic"},
          {"task_prompt", "Something else."}
        ] do
      exec!(ctx.fixture.conn, "UPDATE scheduled_jobs SET #{column} = ? WHERE id = ?", [
        value,
        ctx.fixture.job.id
      ])

      assert {:ok, changed} = Pins.digest(mandate, ctx.seams)
      refute changed == digest
    end
  end

  describe "update_job on a mandated job (design §10.4, C35)" do
    setup ctx do
      previous = Application.get_env(:fermix_core, :cues)
      Application.put_env(:fermix_core, :cues, Keyword.fetch!(ctx.seams, :config))

      on_exit(fn ->
        if previous,
          do: Application.put_env(:fermix_core, :cues, previous),
          else: Application.delete_env(:fermix_core, :cues)
      end)

      :ok
    end

    test "needs the owner's consent turn, and disables the mandate until it is approved again",
         ctx do
      assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), ctx.seams)
      args = %{"job_id" => ctx.fixture.job.id, "task" => "Open an issue for every release note."}

      assert {:ok, %{success: false, error: refused}} =
               UpdateJob.execute(args, turn(ctx, tainted: true))

      assert refused =~ "change it from a private chat with Fermix"
      assert {:ok, %{state: :approved}} = Pins.status(@name, ctx.seams)

      assert {:ok, %{success: true}} = UpdateJob.execute(args, turn(ctx, tainted: false))

      assert {:ok, %{state: :disabled, disabled_reason: "the task was changed with update_job"}} =
               Pins.status(@name, ctx.seams)

      assert {:ok, %{state: :approved}} = Pins.approve(@name, "test", F.now(), ctx.seams)
    end
  end

  defp turn(ctx, tainted: tainted?) do
    sources = if tainted?, do: MapSet.new([{:tool, "web_fetch"}]), else: MapSet.new()

    %{
      session_id: "pins-#{System.unique_integer([:positive])}",
      agent_name: "main",
      source_trust: :operator,
      computer_use_origin: :interactive,
      chat_type: "private",
      channel: "telegram",
      outside_sources: sources,
      memory_repo: ctx.fixture.repo,
      # These are consent tests: a host whose kernel holds commands, so a
      # tainted turn meets the consent refusal, not the host-command one.
      os_sandbox: [os: {:unix, :darwin}]
    }
  end
end
