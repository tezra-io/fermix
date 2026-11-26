defmodule FermixChannels.Companion.AppInboxTest do
  # M106 §8, §11.1, D3, D12 (stage S6): with a phone paired the Fermix app is
  # the owner's inbox, and an ask there is the approval card every app
  # already draws. A heal's card goes to the Mac and the phones as an
  # `approval` of kind `job_change` (never a proposal), pushed for its
  # lifetime, offered again from its record after every hello and restart,
  # answered from the app's one origin, and resolved there however it ends.
  # An access confirmation with no chat of its own takes the same road.
  #
  # async: false — the store the adapters reach, the push and its launcher
  # are application env, and the phones' subtree is marked running by name.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Output
  alias FermixChannels.Gateway.Authorization
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.OwnerInboxApproval
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Jobs.HealCard
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.AppInbox
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.HealCards

  @env ~w(companion_approvals mobile_approval_push mobile_push_launcher)a
  @app OwnerInbox.app_origin("main")

  setup do
    test_pid = self()
    previous = Map.new(@env, &{&1, Application.fetch_env(:fermix_channels, &1)})
    listener = Application.fetch_env(:fermix_core, :app_approval_listener)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:fermix_channels, key, value)
        {key, :error} -> Application.delete_env(:fermix_channels, key)
      end)

      case listener do
        {:ok, value} -> Application.put_env(:fermix_core, :app_approval_listener, value)
        :error -> Application.delete_env(:fermix_core, :app_approval_listener)
      end
    end)

    %{repo: repo} = CueFixtures.start_repo("app_inbox")
    now = DateTime.add(HealCards.delivered_at(), 600, :second)
    durable = &Approvals.job_change_cards(&1, repo: repo, now: now)
    store = start_store!(durable)

    Application.put_env(:fermix_channels, :companion_approvals, store)
    Application.put_env(:fermix_core, :app_approval_listener, Approvals)

    Application.put_env(:fermix_channels, :mobile_approval_push, fn profile, ttl_s ->
      send(test_pid, {:approval_push, profile, ttl_s})
      {:ok, %{status: :sent, sent: 1}}
    end)

    Application.put_env(:fermix_channels, :mobile_push_launcher, fn task ->
      task.()
      :ok
    end)

    # The phones' subtree runs: its supervisor's name is registered.
    start_supervised!(%{
      id: :phone_subtree,
      start: {Agent, :start_link, [fn -> :phone_subtree end, [name: MobileSupervisor]]}
    })

    %{repo: repo, now: now, durable: durable, store: store}
  end

  describe "a heal's card" do
    test "goes to the Mac and the phones as an approval card, pushed for its lifetime", ctx do
      %{job: job, heal: heal} = HealCards.waiting_card!(ctx.repo, @app)
      spec = job.name |> HealCard.app_card(heal.change) |> HealCard.app_spec(heal.id, 604_800)

      assert :ok =
               OwnerInboxApproval.send_cue_proposal(
                 %{platform: "companion", destination: "main"},
                 spec,
                 adapter: Companion
               )

      assert_received {:announced, "main", card, :all}

      assert %{
               "t" => "approval",
               "kind" => "job_change",
               "token" => token,
               "ttl_s" => 604_800,
               "approve_command" => approve,
               "deny_command" => deny,
               "text" => text,
               "detail" => detail
             } = card

      assert {token, approve, deny} ==
               {heal.id, "/confirm #{heal.id}", "/deny #{heal.id}"}

      assert text == ~s(Change job "#{job.name}"?\n- Schedule: "every 2 hours")
      assert detail =~ "Schedule after the change: every 2 hours"
      assert_received {:approval_push, "main", 604_800}

      # Not kept in memory: what a hello offers is read from its record, once.
      assert [offered] = Approvals.pending(ctx.store, "main", :companion)
      assert offered["approval_id"] == card["approval_id"]
      refute_received {:announced, _profile, %{"t" => "proposal" <> _rest}, _audience}
    end

    test "comes back after a hello on either transport, and after a restart", ctx do
      %{heal: heal} = HealCards.waiting_card!(ctx.repo, @app)
      approval_id = Output.approval_id(:job_change, heal.id)
      left = 7 * 86_400 - 600

      for transport <- [:companion, :mobile] do
        assert [%{"approval_id" => ^approval_id, "ttl_s" => ^left}] =
                 Approvals.pending(ctx.store, "main", transport)
      end

      # The engine restarts: the store comes back empty, the record does not.
      stop_supervised!(:app_inbox_store)
      store = start_store!(ctx.durable)

      assert [%{"approval_id" => ^approval_id, "ttl_s" => ^left}] =
               Approvals.pending(store, "main", :mobile)
    end

    test "the Mac's Approve and the phone's Deny reach the rail, and the app is told", ctx do
      %{heal: approved} = HealCards.waiting_card!(ctx.repo, @app)
      %{heal: denied} = HealCards.waiting_card!(ctx.repo, @app)

      dispatch(app_message("companion", "/confirm #{approved.id}"), ctx)
      assert_receive {:reply, "Fermix made the change it proposed to job " <> _rest}, 10_000
      assert_resolved(approved.id, "approved")

      dispatch(app_message("mobile", "/deny #{denied.id}"), ctx)
      assert_receive {:reply, "Job " <> _rest}, 10_000
      assert_resolved(denied.id, "denied")

      assert [] = Approvals.pending(ctx.store, "main", :companion)
    end

    test "an answer from elsewhere is refused, and an edit made elsewhere ends it", ctx do
      %{job: job, heal: heal} = HealCards.waiting_card!(ctx.repo, @app)

      dm =
        Message.new!(%{
          id: "dm-#{System.unique_integer([:positive])}",
          content: "/confirm #{heal.id}",
          sender: "owner",
          channel: "telegram",
          chat_id: "40017",
          reply_target: "40017",
          metadata: %{user_id: "40017"}
        })

      dispatch(dm, ctx)
      assert_receive {:reply, "That card is not waiting in this chat; nothing ran."}, 10_000
      refute_received {:announced, _profile, %{"t" => "approval_resolved"}, _audience}

      {:ok, _edited} =
        JobsRegistry.update_job(job.id, %{task_prompt: "Read the tide board."},
          repo: ctx.repo,
          scheduler: nil
        )

      assert_resolved(heal.id, "expired")

      assert {:ok, %{outcome: "superseded"}} =
               Repo.job_heals_call({:get, heal.id}, server: ctx.repo)
    end
  end

  describe "an access confirmation with no chat of its own" do
    test "reaches the Mac and the phones, is answered from the phone, and resolves on both",
         ctx do
      request = %{access_sensitive: unique_intent(), prompt: "Confirm harbour_gate_open?"}

      assert {:ok, token, :new} =
               OwnerInboxApproval.request(request, AppInbox.opts() ++ [adapter: Companion])

      assert_received {:announced, "main",
                       %{"t" => "approval", "kind" => "sandbox", "token" => ^token} = card, :all}

      assert_received {:approval_push, "main", 60}

      assert {:ok, %{channel: "companion", chat_id: "main", user_id: "app"}} =
               Confirmations.peek(token)

      assert [%{"token" => ^token}] = Approvals.pending(ctx.store, "main", :mobile)
      assert [%{"token" => ^token}] = Approvals.pending(ctx.store, "main", :companion)

      resolution = fn %{kind: kind, token: token, outcome: outcome} ->
        Approvals.resolve(
          ctx.store,
          "main",
          Output.approval_resolved(kind, token, outcome),
          :mobile
        )
      end

      dispatch(app_message("mobile", "/confirm #{token}"), ctx,
        approval_resolution_fn: resolution
      )

      assert_receive {:reply, "Confirmed, but " <> _rest}, 10_000

      assert_received {:announced, "main",
                       %{
                         "t" => "approval_resolved",
                         "approval_id" => id,
                         "outcome" => "approved"
                       }, :all}

      assert id == card["approval_id"]
      assert :error = Confirmations.peek(token)
    end

    test "is not answered from a DM", ctx do
      request = %{access_sensitive: unique_intent(), prompt: "Confirm quay_lights_on?"}

      assert {:ok, token, :new} =
               OwnerInboxApproval.request(request, AppInbox.opts() ++ [adapter: Companion])

      # The application's one confirmation store: what this test left is taken.
      on_exit(fn -> Confirmations.take(token) end)

      dm =
        Message.new!(%{
          id: "dm-#{System.unique_integer([:positive])}",
          content: "/confirm #{token}",
          sender: "owner",
          channel: "telegram",
          chat_id: "40017",
          reply_target: "40017",
          metadata: %{user_id: "40017"}
        })

      dispatch(dm, ctx)
      assert_receive {:reply, "Confirmation failed: :origin_mismatch"}, 10_000
      assert {:ok, _still_waiting} = Confirmations.peek(token)
    end
  end

  # --- helpers -------------------------------------------------------------------------

  # The application's confirmation store is one for the suite: every request
  # here is its own, so none answers another's as already waiting.
  defp unique_intent, do: "intent-#{System.unique_integer([:positive])}"

  defp start_store!(durable) do
    test_pid = self()

    start_supervised!(
      {Approvals,
       name: nil,
       schedule: fn _message, _delay_ms -> make_ref() end,
       announce: fn profile, event, audience ->
         send(test_pid, {:announced, profile, event, audience})
         :ok
       end,
       durable: durable},
      id: :app_inbox_store
    )
  end

  defp assert_resolved(heal_id, outcome) do
    approval_id = Output.approval_id(:job_change, heal_id)

    assert_receive {:announced, "main",
                    %{
                      "t" => "approval_resolved",
                      "approval_id" => ^approval_id,
                      "outcome" => ^outcome
                    }, :all},
                   10_000
  end

  # A command typed in the app: the Mac chat or a paired phone, in its chat
  # `main`, each transport authenticated by itself (the operator here).
  defp app_message(channel, content) do
    Message.new!(%{
      id: "app-#{System.unique_integer([:positive])}",
      content: content,
      sender: "Companion owner",
      channel: channel,
      chat_id: "main",
      reply_target: "main",
      metadata: %{}
    })
  end

  defp dispatch(message, ctx, extra \\ []) do
    test_pid = self()

    reply_fn = fn
      {:text, text} -> send(test_pid, {:reply, text})
      other -> send(test_pid, {:reply, other})
    end

    context =
      Map.merge(
        %{
          authorization: %Authorization{role: :operator, trust: :operator},
          conversation_key: {"companion", "main", :root},
          cue_proposal_opts: [repo: ctx.repo, now: ctx.now, scheduler: nil]
        },
        Map.new(extra)
      )

    Commands.dispatch(Commands.parse(message), reply_fn, context)
  end
end
