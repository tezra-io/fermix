defmodule FermixWebWeb.SetupLiveModelSourceTest do
  # M107: the setup page asks a provider for its model list only from a
  # connected page whose Provider tab is showing, only for a source it has not
  # read yet (or when the owner presses Refresh), and never on the page's own
  # process. A source is everything the answer depends on: the provider, the
  # pane's inputs (Ollama's base URL as edited, Vercel AI Gateway's key as
  # typed), the configured values the listing reads without them, the ChatGPT
  # sign-in, and the engine's role. Every case runs in a temporary FERMIX_HOME
  # against the stub keychain, with the whole environment of the three
  # applications put back afterwards. Every name, key and address here is
  # invented.
  use FermixWebWeb.ConnCase

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias FermixCore.Auth.Store
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.PhoneCallGoldens
  alias FermixTestSupport.SecretWriterStub
  alias FermixWebWeb.SetupLive.ModelSource

  @apps [:fermix_core, :fermix_channels, :fermix_web]
  @provider_form ~s(form[phx-submit="save_provider"])
  @configured_key "vck-configured-key"
  @ollama_a "http://ollama-a.test:11434/v1"
  @ollama_b "http://ollama-b.test:11434/v1"
  # The most reports one look reads; every case expects far fewer.
  @max_reports 20

  # A provider's listing as the page meets it: each request is reported to the
  # test (the provider, the options it was asked with and the process it ran
  # in) and answered at once with one model named for what it was asked with.
  defmodule CountingListing do
    @live [:ollama, :vercel, :openai_codex]

    def live?(provider), do: provider in @live

    def live_models(provider, opts) when provider in @live do
      send(
        Process.whereis(FermixWebWeb.SetupLiveModelSourceTest),
        {:listing, provider, opts, self()}
      )

      {:ok, [%{id: listed_id(provider, opts), label: "Listed", context_window: nil}]}
    end

    defp listed_id(:ollama, opts), do: "pulled-on/" <> URI.parse(opts[:base_url]).host
    defp listed_id(:vercel, api_key: key), do: "team/key-#{byte_size(key)}"
    defp listed_id(:vercel, []), do: "public/every-model"
    defp listed_id(:openai_codex, []), do: "gpt-plan-alpha"
  end

  # The same report, and an answer only once the test sends one to the process
  # the request runs in, the way a slow provider answers.
  defmodule HeldListing do
    @live [:ollama, :vercel]

    def live?(provider), do: provider in @live

    def live_models(provider, opts) when provider in @live do
      send(
        Process.whereis(FermixWebWeb.SetupLiveModelSourceTest),
        {:listing, provider, opts, self()}
      )

      receive do
        {:answer, answer} -> answer
      end
    end
  end

  # A listing that stops before it answers.
  defmodule StoppingListing do
    def live?(provider), do: provider == :ollama
    def live_models(:ollama, _opts), do: raise("the listing stopped")
  end

  setup %{conn: conn} do
    envs = for app <- @apps, do: {app, Application.get_all_env(app)}
    fermix_home = System.get_env("FERMIX_HOME")
    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live-model-source")
    System.put_env("FERMIX_HOME", tmp_home)
    SecretWriterStub.reset()
    Process.register(self(), __MODULE__)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.put_env(:fermix_core, :tools, [])
    Application.put_env(:fermix_core, :routing, [])
    Application.put_env(:fermix_core, :harness, [])
    Application.put_env(:fermix_core, :meetings, enabled: false)
    Application.put_env(:fermix_core, :phone_calls, [])
    Application.put_env(:fermix_core, :realtime, [])

    Application.put_env(:fermix_core, :transcription,
      backend: "openai",
      model: "gpt-4o-mini-transcribe",
      max_file_mb: 20
    )

    Application.delete_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_web, :harness_detector, fn -> %{} end)
    Application.put_env(:fermix_web, :model_listing_impl, CountingListing)

    Application.put_env(:fermix_web, :phone_calls,
      management: [
        readiness: PhoneCallGoldens.host(),
        manager: :"setup_model_source_no_manager_#{System.unique_integer([:positive])}"
      ],
      settings: []
    )

    primary(:vercel, api_key: @configured_key, default_model: "vendor/demo")

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

  describe "when the page asks" do
    # The doc's probe: before this, the mount asked twice and every model edit
    # once more.
    test "a page opened on another tab asks nothing until Provider shows, then once per source",
         %{conn: conn} do
      conn = get(conn, "/setup?tab=phone_calls")
      assert reported() == []

      {:ok, view, _html} = live(conn)
      assert requests(view) == []

      render_click(view, "select_tab", %{"tab" => "provider"})
      assert [{:vercel, [], pid}] = requests(view)
      refute pid == view.pid
      assert render(view) =~ "public/every-model"

      for slug <- ~w(vendor/demo1 vendor/demo2 vendor/demo3) do
        assert change(view, %{provider: "vercel", default_model: slug}) =~ "public/every-model"
        assert requests(view) == []
      end

      change(view, %{provider: "vercel", subagent_model: vercel_catalog_model()})
      assert requests(view) == []

      render_click(view, "select_tab", %{"tab" => "personalization"})

      view
      |> form("form[phx-submit=\"save_personalization\"]",
        personalization_form: %{
          user_name: "Ines",
          timezone: "Europe/Lisbon",
          communication_style: "brief"
        }
      )
      |> render_submit()

      assert render(view) =~ "Personalization saved."
      assert requests(view) == []

      render_click(view, "select_tab", %{"tab" => "provider"})
      assert requests(view) == []
      assert render(view) =~ "public/every-model"
    end

    test "the static render asks nothing and shows the picker loading; the live page asks once",
         %{conn: conn} do
      conn = get(conn, "/setup?tab=provider")
      assert html_response(conn, 200) =~ ~s(id="live-models-loading")
      assert reported() == []

      {:ok, view, _html} = live(conn)
      assert [{:vercel, [], pid}] = requests(view)
      refute pid == view.pid
    end

    test "Back to the Provider tab asks once; Back on the first tab asks nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=realtime")
      assert requests(view) == []

      render_click(view, "previous_step", %{})
      assert [{:vercel, [], _pid}] = requests(view)

      render_click(view, "previous_step", %{})
      assert requests(view) == []
    end

    test "a save on the Provider tab that changes only the model asks nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [_first] = requests(view)

      view
      |> form(@provider_form, provider_form: %{provider: "vercel", default_model: "vendor/other"})
      |> render_submit()

      assert render(view) =~ "Provider saved."
      assert requests(view) == []
    end
  end

  describe "a changed source asks once" do
    test "switching the provider card, back to one shown before too", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [{:vercel, [], _pid}] = requests(view)

      change(view, %{provider: "ollama"})
      assert [{:ollama, [base_url: _url], _pid}] = requests(view)

      change(view, %{provider: "openai"})
      assert requests(view) == []

      change(view, %{provider: "vercel"})
      assert [{:vercel, [], _pid}] = requests(view)
    end

    test "editing the Ollama base URL, and not editing anything else", %{conn: conn} do
      primary(:ollama, base_url: @ollama_a, default_model: "qwen3:32b")
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [{:ollama, [base_url: @ollama_a], _pid}] = requests(view)

      change(view, %{provider: "ollama", ollama_base_url: @ollama_b})
      assert [{:ollama, [base_url: @ollama_b], _pid}] = requests(view)
      assert render(view) =~ "pulled-on/ollama-b.test"

      change(view, %{provider: "ollama", ollama_base_url: @ollama_b, default_model: "typed:1b"})
      assert requests(view) == []
    end

    test "entering, changing and clearing the Vercel AI Gateway key", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [{:vercel, [], _pid}] = requests(view)

      change(view, %{provider: "vercel", vercel_api_key: "vck-entered"})
      assert [{:vercel, [api_key: "vck-entered"], _pid}] = requests(view)
      assert render(view) =~ "team/key-11"

      # The browser keeps the typed key and posts it with every other edit.
      change(view, %{provider: "vercel", vercel_api_key: "vck-entered", default_model: "x/y"})
      assert requests(view) == []

      change(view, %{provider: "vercel", vercel_api_key: "vck-changed-key"})
      assert [{:vercel, [api_key: "vck-changed-key"], _pid}] = requests(view)

      change(view, %{provider: "vercel", vercel_api_key: "  "})
      assert [{:vercel, [], _pid}] = requests(view)
      assert render(view) =~ "public/every-model"
    end

    # M105 §11.9: the pane shown again draws an empty key field, so its list
    # is the configured key's, not the team's of a key no longer entered.
    test "back on the Provider tab after a typed key, the configured key's list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [_first] = requests(view)

      change(view, %{provider: "vercel", vercel_api_key: "vck-entered"})
      assert [{:vercel, [api_key: "vck-entered"], _pid}] = requests(view)

      render_click(view, "select_tab", %{"tab" => "search"})
      assert requests(view) == []

      render_click(view, "select_tab", %{"tab" => "provider"})
      assert [{:vercel, [], _pid}] = requests(view)
      assert render(view) =~ "public/every-model"
      refute render(view) =~ "team/key-11"
    end

    test "a saved key", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [_first] = requests(view)

      view
      |> form(@provider_form, provider_form: %{provider: "vercel", vercel_api_key: "vck-saved"})
      |> render_submit()

      assert render(view) =~ "Provider saved."
      assert [{:vercel, [], _pid}] = requests(view)
    end

    test "a saved base URL", %{conn: conn} do
      primary(:ollama, base_url: @ollama_a, default_model: "qwen3:32b")
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [_first] = requests(view)

      view
      |> form(@provider_form, provider_form: %{provider: "ollama", ollama_base_url: @ollama_b})
      |> render_submit()

      assert render(view) =~ "Provider saved."
      assert [{:ollama, [base_url: @ollama_b], _pid}] = requests(view)
    end

    # The sign-in's own model check (`LiveModel.ensure/2`) reads the list on
    # the page's process, as before; the picker reads it once more, off it.
    test "a completed ChatGPT sign-in, then a sign-out", %{conn: conn} do
      test = self()

      Application.put_env(:fermix_web, :chatgpt_login_runner, fn opts ->
        send(test, {:signing_in, self()})
        :ok = Keyword.fetch!(opts, :opener).("https://auth.openai.test/authorize")
        :ok = Store.write("chatgpt", chatgpt_entry())
        {:ok, %{account: "ines@example.test", plan_usage: :on}}
      end)

      Application.put_env(:fermix_web, :chatgpt_logout_runner, fn _opts ->
        :ok = Store.delete_provider("chatgpt")
        {:ok, %{revoked: true}}
      end)

      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [_first] = requests(view)

      change(view, %{provider: "openai_codex"})
      assert [{:openai_codex, [], _pid}] = requests(view)

      view |> element(~s(button[phx-click="chatgpt_login"])) |> render_click()
      assert_receive {:signing_in, sign_in}
      await_exit(sign_in)

      {on_page, off_page} = Enum.split_with(requests(view), &(elem(&1, 2) == view.pid))
      assert [{:openai_codex, [], _page}] = on_page
      assert [{:openai_codex, [], _task}] = off_page
      assert render(view) =~ "gpt-plan-alpha"

      view |> element(~s(button[phx-click="chatgpt_logout"])) |> render_click()
      assert [{:openai_codex, [], pid}] = requests(view)
      refute pid == view.pid
      assert render(view) =~ "Continue with ChatGPT"
    end
  end

  describe "an answer" do
    test "for an older Ollama base URL is dropped", %{conn: conn} do
      primary(:ollama, base_url: @ollama_a, default_model: "qwen3:32b")
      Application.put_env(:fermix_web, :model_listing_impl, HeldListing)
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert_receive {:listing, :ollama, [base_url: @ollama_a], first}
      assert has_element?(view, "#live-models-loading")

      change(view, %{provider: "ollama", ollama_base_url: @ollama_b})
      assert_receive {:listing, :ollama, [base_url: @ollama_b], second}

      answer(first, "pulled-on/ollama-a.test")
      refute render(view) =~ "pulled-on/ollama-a.test"
      assert has_element?(view, "#live-models-loading")

      answer(second, "pulled-on/ollama-b.test")
      html = render_async(view)
      assert html =~ "pulled-on/ollama-b.test"
      refute html =~ "pulled-on/ollama-a.test"
      refute has_element?(view, "#live-models-loading")
    end

    test "for a key no longer typed is dropped", %{conn: conn} do
      Application.put_env(:fermix_web, :model_listing_impl, HeldListing)
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert_receive {:listing, :vercel, [], configured}

      change(view, %{provider: "vercel", vercel_api_key: "vck-first-key"})
      assert_receive {:listing, :vercel, [api_key: "vck-first-key"], first}

      change(view, %{provider: "vercel", vercel_api_key: "vck-second-key"})
      assert_receive {:listing, :vercel, [api_key: "vck-second-key"], second}

      answer(configured, "public/every-model")
      answer(first, "team/first-key-model")
      html = render(view)
      refute html =~ "public/every-model"
      refute html =~ "team/first-key-model"

      answer(second, "team/second-key-model")
      html = render_async(view)
      assert html =~ "team/second-key-model"
      refute html =~ "team/first-key-model"
      refute html =~ "public/every-model"
    end

    test "leaves the edits typed while it was loading as they were typed", %{conn: conn} do
      Application.put_env(:fermix_web, :model_listing_impl, HeldListing)
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert_receive {:listing, :vercel, [], pending}

      subagent = vercel_catalog_model()

      html =
        change(view, %{
          provider: "vercel",
          default_model: "typed/while-loading",
          subagent_model: subagent
        })

      assert model_input(html) =~ ~s(value="typed/while-loading")

      answer(pending, "public/every-model")
      html = render_async(view)
      assert html =~ "public/every-model"
      assert model_input(html) =~ ~s(value="typed/while-loading")

      assert has_element?(
               view,
               ~s(select[name="provider_form[subagent_model]"] option[value="#{subagent}"][selected])
             )
    end

    test "is loading until it arrives, in an editable field holding the form's model", %{
      conn: conn
    } do
      Application.put_env(:fermix_web, :model_listing_impl, HeldListing)
      {:ok, view, html} = live(conn, "/setup?tab=provider")
      assert_receive {:listing, :vercel, [], pending}

      assert has_element?(view, "#live-models-loading")
      input = model_input(html)
      assert input =~ ~s(type="text")
      assert input =~ ~s(value="vendor/demo")
      refute has_element?(view, ~s(button[phx-click="refresh_models"]))

      answer(pending, "public/every-model")
      render_async(view)
      refute has_element?(view, "#live-models-loading")
    end

    test "from a listing that stopped is the error state", %{conn: conn} do
      primary(:ollama, base_url: @ollama_a, default_model: "qwen3:32b")
      Application.put_env(:fermix_web, :model_listing_impl, StoppingListing)

      log =
        capture_log(fn ->
          {:ok, view, _html} = live(conn, "/setup?tab=provider")
          send(self(), {:rendered, render_async(view)})
        end)

      assert_received {:rendered, html}

      assert html =~
               "Couldn&#39;t fetch the live model list (the listing stopped before it answered)"

      assert html =~ "No Ollama server responded"
      refute html =~ "live-models-loading"
      assert log =~ "the ollama model listing stopped: RuntimeError"
    end
  end

  describe "Refresh" do
    test "asks the source shown once more", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [_first] = requests(view)

      view |> element(~s(button[phx-click="refresh_models"])) |> render_click()
      assert [{:vercel, [], pid}] = requests(view)
      refute pid == view.pid
    end

    # The page keeps no typed key, so it cannot ask that source again itself.
    test "is not offered while the list is a typed key's", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [_first] = requests(view)

      change(view, %{provider: "vercel", vercel_api_key: "vck-entered"})
      assert [_typed] = requests(view)
      refute has_element?(view, ~s(button[phx-click="refresh_models"]))

      render_click(view, "refresh_models", %{})
      assert requests(view) == []
    end

    # The on-device speech install puts a speech model on this computer; no
    # provider's model list reads it, so its end asks nothing.
    test "is not what the on-device speech install's end does", %{conn: conn} do
      test = self()

      Application.put_env(:fermix_core, :transcription,
        backend: "openai",
        max_file_mb: 20,
        local_offered: true
      )

      Application.put_env(:fermix_web, :local_installer, fn _opts ->
        send(test, :installed)
        :ok
      end)

      Application.put_env(:fermix_web, :local_transcription_opts,
        releases: FermixTestSupport.SttPins.for_this_host()
      )

      {:ok, view, _html} = live(conn, "/setup?tab=provider")
      assert [_first] = requests(view)

      render_click(view, "select_tab", %{"tab" => "transcription"})

      view
      |> form("form[phx-submit=\"save_transcription\"]", transcription_form: %{backend: "local"})
      |> render_change()

      assert requests(view) == []
      assert_received :installed

      render_click(view, "select_tab", %{"tab" => "provider"})
      assert requests(view) == []
    end
  end

  test "a device-role engine reaches no provider's list", %{conn: conn} do
    Application.put_env(:fermix_web, :engine_role, fn ->
      %{role: :device, primary: "aws i-0f3b1c"}
    end)

    {:ok, view, _html} = live(conn, "/setup?tab=provider")
    render_change(view, "provider_changed", %{"provider_form" => %{"provider" => "ollama"}})
    render_click(view, "refresh_models", %{})
    render_click(view, "select_tab", %{"tab" => "search"})
    render_click(view, "select_tab", %{"tab" => "provider"})

    assert requests(view) == []
  end

  describe "ModelSource.source/4" do
    test "the same inputs make the same source" do
      assert ModelSource.source(:vercel, [api_key: "vck-a"], [base_url: "https://g.test"], nil) ==
               ModelSource.source(:vercel, [api_key: "vck-a"], [base_url: "https://g.test"], nil)
    end

    test "each input the answer depends on changes it" do
      signed_in = %{state: :connected, account: "ines@example.test"}
      base = ModelSource.source(:ollama, [base_url: @ollama_a], [], nil)

      refute ModelSource.source(:vercel, [base_url: @ollama_a], [], nil) == base
      refute ModelSource.source(:ollama, [base_url: @ollama_b], [], nil) == base
      refute ModelSource.source(:ollama, [], [base_url: @ollama_b], nil) == base

      assert ModelSource.source(:ollama, [], [base_url: @ollama_a], nil) == base

      vercel = ModelSource.source(:vercel, [], [api_key: "vck-a"], nil)
      refute ModelSource.source(:vercel, [api_key: "vck-b"], [api_key: "vck-a"], nil) == vercel
      refute ModelSource.source(:vercel, [], [api_key: "vck-b"], nil) == vercel
      refute ModelSource.source(:vercel, [], [], nil) == vercel

      refute ModelSource.source(:vercel, [], [api_key: "vck-a", base_url: "https://g.test"], nil) ==
               vercel

      # A key typed in the pane that is the configured one is the same answer.
      assert ModelSource.source(:vercel, [api_key: "vck-a"], [api_key: "vck-a"], nil) == vercel

      codex = ModelSource.source(:openai_codex, [], [], signed_in)
      refute ModelSource.source(:openai_codex, [], [], %{signed_in | state: :plan_off}) == codex

      refute ModelSource.source(:openai_codex, [], [], %{signed_in | account: "rui@example.test"}) ==
               codex
    end

    test "a value the listing does not read leaves it alone" do
      ollama = ModelSource.source(:ollama, [base_url: @ollama_a], [], nil)

      assert ModelSource.source(:ollama, [base_url: @ollama_a], [base_url: @ollama_b], nil) ==
               ollama

      assert ModelSource.source(:ollama, [base_url: @ollama_a], [api_key: "unused"], nil) ==
               ollama
    end

    test "holds a key only as its digest" do
      for source <- [
            ModelSource.source(:vercel, [api_key: "vck-typed-secret"], [], nil),
            ModelSource.source(:vercel, [], [api_key: "vck-configured-secret"], nil)
          ] do
        bytes = :erlang.term_to_binary(source)
        assert :binary.match(bytes, "vck-typed-secret") == :nomatch
        assert :binary.match(bytes, "vck-configured-secret") == :nomatch
        refute inspect(source) =~ "secret"
      end
    end
  end

  # The listings the page asked for since the last look, as `{provider,
  # options, process}`. Every task the page started has ended once
  # `render_async/1` returns, so each one has reported; an answer can start one
  # more (a sign-out's starts the listing), hence the second round.
  defp requests(view) do
    render_async(view)
    render_async(view)
    reported()
  end

  defp reported do
    Enum.flat_map(1..@max_reports, fn _look ->
      receive do
        {:listing, provider, opts, pid} -> [{provider, opts, pid}]
      after
        0 -> []
      end
    end)
  end

  defp answer(task, id) do
    send(task, {:answer, {:ok, [%{id: id, label: "Listed", context_window: nil}]}})
    await_exit(task)
  end

  # Once the process ended, what it sent the page is already in the page's
  # mailbox, ahead of anything the test asks the page afterwards.
  defp await_exit(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  defp change(view, fields),
    do: view |> form(@provider_form, provider_form: fields) |> render_change()

  defp model_input(html),
    do: hd(Regex.run(~r/<input[^>]*name="provider_form\[default_model\]"[^>]*>/, html))

  defp vercel_catalog_model, do: ModelCatalog.models_for(:vercel) |> hd() |> Map.fetch!(:id)

  defp primary(provider, block) do
    Application.put_env(:fermix_core, :providers, [{provider, [{:primary, true} | block]}])
    Application.put_env(:fermix_core, :agent, name: "fermix", provider: provider)
    :ok = ConfigStore.save_snapshot(ConfigStore.current_snapshot())
    :ok = RestartState.record_persisted_baseline()
  end

  defp chatgpt_entry do
    %{
      auth_mode: "oauth_siwc",
      provider: "chatgpt",
      client_id: "oaiapp_Q7m",
      subject: "user-sub-q7m",
      account: %{email: "ines@example.test"},
      granted_scopes:
        ~w(openid profile email offline_access resource.invoke chatgpt.tokens.use.direct),
      tokens: %{access_token: "AT-q7m", refresh_token: "RT-q7m"},
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      last_refresh: nil,
      status: "ready"
    }
  end

  defp restore_all(app, env) do
    for {key, _value} <- Application.get_all_env(app),
        not Keyword.has_key?(env, key),
        do: Application.delete_env(app, key)

    for {key, value} <- env, do: Application.put_env(app, key, value)
  end
end
