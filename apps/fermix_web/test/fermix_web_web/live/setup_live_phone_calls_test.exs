defmodule FermixWebWeb.SetupLivePhoneCallsTest do
  # The setup page's Phone calls section (M94 §12), under the Realtime tab:
  # drawn from the `phone_calls` settings section and `Management.PhoneCalls`
  # in the page's own process, written through the same management writers as
  # the socket's. Every case runs in a temporary FERMIX_HOME against the stub
  # keychain, with the whole environment of the three applications put back
  # afterwards. Every name, number and credential here is invented.
  use FermixWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FermixCore.Management.PhoneCalls, as: ManagementPhoneCalls
  alias FermixCore.Management.Secrets, as: ManagementSecrets
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Readiness
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.PhoneCallGoldens
  alias FermixTestSupport.SecretWriterStub

  @apps [:fermix_core, :fermix_channels, :fermix_web]
  @caller "+14155550142"
  @password "invented-trunk-password"
  @key "sk-invented-openai-key"
  @new_key "sk-another-invented-key"

  setup %{conn: conn} do
    envs = for app <- @apps, do: {app, Application.get_all_env(app)}
    fermix_home = System.get_env("FERMIX_HOME")
    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live-phone-calls")
    System.put_env("FERMIX_HOME", tmp_home)
    SecretWriterStub.reset()

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)
    Application.put_env(:fermix_core, :tools, [])
    Application.put_env(:fermix_core, :routing, [])
    Application.put_env(:fermix_core, :harness, [])
    Application.put_env(:fermix_core, :meetings, enabled: false)
    Application.put_env(:fermix_core, :phone_calls, [])

    Application.put_env(:fermix_core, :realtime,
      enabled: true,
      engine: "xai_realtime",
      model: "grok-voice-3.0",
      voice: "eve"
    )

    Application.put_env(:fermix_core, :transcription,
      backend: "openai",
      model: "gpt-4o-mini-transcribe",
      max_file_mb: 20
    )

    Application.delete_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_web, :harness_detector, fn -> %{} end)
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      Enum.each(envs, fn {app, env} -> restore_all(app, env) end)
      SecretWriterStub.reset()

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{conn: authorize_setup(conn)}
  end

  # The facts a test host cannot settle (it is the primary, memory is on),
  # and a call manager that never runs.
  defp page(conn, management \\ host(), settings \\ []) do
    Application.put_env(:fermix_web, :phone_calls, management: management, settings: settings)
    live(conn, "/setup?tab=realtime")
  end

  defp host,
    do: [
      readiness: PhoneCallGoldens.host(),
      manager: :"setup_phone_no_manager_#{System.unique_integer([:positive])}"
    ]

  test "the Realtime tab draws Phone calls off, with the engine that calls", %{conn: conn} do
    {:ok, view, _html} = page(conn)

    assert has_element?(view, "#phone-calls")
    assert has_element?(view, "#phone-calls-switch")
    assert view |> element("#phone-calls-summary") |> render() =~ "Disabled"
    assert view |> element("#phone-calls-engine") |> render() =~ "GPT-Live"
    assert has_element?(view, "#phone-calls-form select[name='phone_calls[voice]']")
  end

  test "saving writes the settings and the password, and leaves Talk to Fermix alone",
       %{conn: conn} do
    test = self()
    switch = fn on? -> send(test, {:phone_calls_switch, on?}) && [] end
    {:ok, view, _html} = page(conn, host(), phone_calls_switch: switch)
    realtime = RealtimeConfig.normalize(Application.get_env(:fermix_core, :realtime))

    view
    |> form("#phone-calls-form",
      phone_calls: %{
        voice: "cedar",
        caller_number: @caller,
        sip_username: "fermixtrunk01",
        sip_password: @password
      }
    )
    |> render_submit()

    assert %Config{voice: "cedar", caller_number: @caller, sip_username: "fermixtrunk01"} =
             Config.get()

    assert SecretWriterStub.get(:phone_calls_sip_password) == {:ok, @password}
    refute_received {:phone_calls_switch, _on?}

    # On, on a home whose only voice key is SpaceXAI's: the OpenAI key is the
    # one requirement left.
    view |> element("#phone-calls-switch") |> render_submit()
    assert_receive {:phone_calls_switch, true}

    summary = view |> element("#phone-calls-summary") |> render()
    assert summary =~ "Needs setup"
    assert summary =~ Readiness.sentence(:openai_api_key_missing)

    assert RealtimeConfig.normalize(Application.get_env(:fermix_core, :realtime)) == realtime
  end

  test "a number the section refuses is said in the daemon's words", %{conn: conn} do
    {:ok, view, _html} = page(conn)

    view
    |> form("#phone-calls-form", phone_calls: %{caller_number: "4155550142"})
    |> render_submit()

    assert view |> element("#phone-calls-refusal") |> render() =~ "international form"
    assert Config.get().caller_number == nil
  end

  test "a call in progress offers Stop, and Stop asks it to end", %{conn: conn} do
    {:ok, view, _html} = page(conn, PhoneCallGoldens.world(:in_progress))

    assert view |> element("#phone-calls-summary") |> render() =~ "Calling"
    assert view |> element("#phone-calls-call-sentence") |> render() =~ "The call is connected."

    view |> element("#phone-calls-stop") |> render_submit()

    assert view |> element("#phone-calls-notice") |> render() =~
             "Fermix asked OpenAI to end the call. It reads stopping until its end is known"

    assert view |> element("#phone-calls-call-sentence") |> render() =~ "waiting to hear"
    refute has_element?(view, "#phone-calls-stop")
  end

  # The section reads again on a timer while a call is in progress, as the
  # Phone card reads a pairing, and stops once none is; a call that stopped
  # says why in the recent calls.
  test "a call in progress is followed until it ends, and the recent call says why it stopped",
       %{conn: conn} do
    test = self()
    world = PhoneCallGoldens.world(:in_progress)

    Application.put_env(:fermix_web, :phone_calls,
      management: world,
      settings: [],
      schedule: fn message, ms -> send(test, {:scheduled, message, ms}) end
    )

    {:ok, view, _html} = live(conn, "/setup?tab=realtime")
    assert_receive {:scheduled, {:phone_calls_poll, ref} = poll, 2_000}

    fields = %{ended_at: PhoneCallGoldens.now(), failure_reason: "call_failed"}
    id = PhoneCallGoldens.ids().in_progress
    {:ok, _row} = Ledger.terminalize(id, "failed", fields, server: world[:repo])

    send(view.pid, poll)
    recent = view |> element("#phone-calls-recent-why-#{id}") |> render()
    assert recent =~ "OpenAI reported that the call failed."
    refute has_element?(view, "#phone-calls-stop")
    refute_received {:scheduled, {:phone_calls_poll, _next}, _ms}

    # A poll an earlier read scheduled and no longer awaits changes nothing.
    send(view.pid, {:phone_calls_poll, ref})
    assert render(view) =~ "OpenAI reported that the call failed."
  end

  test "an unresolved call shows what is known and the steps at Telnyx", %{conn: conn} do
    opts = PhoneCallGoldens.world(:lost)
    {:ok, view, _html} = page(conn, opts)
    lost = PhoneCallGoldens.ids().lost

    assert {:ok, %{"calls" => [call]}} = ManagementPhoneCalls.recovery(opts)
    recovery = view |> element("#phone-calls-recovery-#{lost}") |> render()

    assert recovery =~ call["destination"]
    assert recovery =~ "Telnyx portal"
    assert recovery =~ "daily spend limit"
    refute has_element?(view, "#phone-calls-stop")
    assert view |> element("#phone-calls-summary") |> render() =~ "Placement unknown"
  end

  test "the owner's word that an unresolved call ended frees its slot", %{conn: conn} do
    opts = PhoneCallGoldens.world(:lost)
    {:ok, view, _html} = page(conn, opts)
    lost = PhoneCallGoldens.ids().lost

    view |> element("#phone-calls-confirm-#{lost}") |> render_submit()

    assert view |> element("#phone-calls-notice") |> render() =~
             "Fermix marked the call ended on your word, so a new call may be placed."

    refute has_element?(view, "#phone-calls-recovery-#{lost}")
    assert {:ok, %{"calls" => []}} = ManagementPhoneCalls.recovery(opts)

    assert {:ok, %{slot_release_reason: "owner_confirmed"}} =
             Ledger.get(lost, server: opts[:repo])
  end

  # M94 §12: the page's Restart is the owner's own, so a call in progress
  # holds it, in the same sentence `fermix restart` and the apps say.
  test "Restart is refused while a call is in progress", %{conn: conn} do
    test = self()
    Application.put_env(:fermix_web, :restarts_itself, fn -> true end)
    Application.put_env(:fermix_web, :restart_stop, fn -> send(test, :restart_stopped) end)
    {:ok, view, _html} = page(conn, PhoneCallGoldens.world(:in_progress))

    html = render_click(view, "apply_restart", %{})

    assert html =~
             "A phone call is in progress, and restarting Fermix now would hang it up without " <>
               "its outcome."

    refute html =~ "Restarting Fermix"
    refute_received :restart_stopped
  end

  # M94 §12: the Providers and Realtime forms write the OpenAI key through the
  # setup save, whose writer holds it while a call is in progress, as it does
  # for `secret.set`. A held save says why and saves nothing.
  describe "the credentials a call reads" do
    @held "A phone call is in progress and uses this key. Ask Fermix to stop the call, or " <>
            "let it end, then change the key."

    setup do
      assert {:ok, %{"present" => true}} = ManagementSecrets.set("openai_api_key", @key)
      world = PhoneCallGoldens.world(:in_progress)
      %{world: world, end_call: fn -> end_call!(world) end}
    end

    test "the Providers form cannot replace the OpenAI key during a call, and can after it",
         %{conn: conn, world: world, end_call: end_call} do
      {:ok, view, _html} = open(conn, "provider", world)
      submit = fn -> render_submit(view, "save_provider", provider_form(@new_key)) end

      html = submit.()
      assert html =~ "Save failed: " <> @held
      refute html =~ "Provider saved."
      assert SecretWriterStub.get(:openai_api_key) == {:ok, @key}

      end_call.()
      assert submit.() =~ "Provider saved."
      assert SecretWriterStub.get(:openai_api_key) == {:ok, @new_key}
    end

    test "the Realtime form cannot replace the key Live speaks with during a call",
         %{conn: conn, world: world, end_call: end_call} do
      Application.put_env(:fermix_core, :realtime,
        enabled: true,
        engine: "openai_live",
        model: "gpt-live-1",
        voice: "marin"
      )

      {:ok, view, _html} = open(conn, "realtime", world)
      submit = fn -> render_submit(view, "save_realtime", realtime_form(@new_key)) end

      html = submit.()
      assert html =~ "Save failed: " <> @held
      refute html =~ "Realtime saved."
      assert SecretWriterStub.get(:openai_api_key) == {:ok, @key}

      end_call.()
      assert submit.() =~ "Realtime saved."
      assert SecretWriterStub.get(:openai_api_key) == {:ok, @new_key}
    end

    test "the Realtime form stores Grok's key during a call: no phone call reads it",
         %{conn: conn, world: world} do
      {:ok, view, _html} = open(conn, "realtime", world)

      assert render_submit(view, "save_realtime", realtime_form("xai-invented-voice-key")) =~
               "Realtime saved."

      assert SecretWriterStub.get(:xai_api_key) == {:ok, "xai-invented-voice-key"}
      assert SecretWriterStub.get(:openai_api_key) == {:ok, @key}
    end
  end

  defp open(conn, tab, management) do
    Application.put_env(:fermix_web, :phone_calls, management: management, settings: [])
    live(conn, "/setup?tab=#{tab}")
  end

  defp provider_form(key),
    do: %{"provider_form" => %{"provider" => "openai", "openai_api_key" => key}}

  defp realtime_form(key), do: %{"realtime_form" => %{"api_key" => key}}

  defp end_call!(world) do
    id = PhoneCallGoldens.ids().in_progress
    fields = %{ended_at: PhoneCallGoldens.now()}
    {:ok, _row} = Ledger.terminalize(id, "ended", fields, server: world[:repo])
    :ok
  end

  defp restore_all(app, env) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(env, key),
        do: Application.delete_env(app, key)

    for {key, value} <- env, do: Application.put_env(app, key, value)
  end
end
