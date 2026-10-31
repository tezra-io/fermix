defmodule FermixCore.Browser.SignInTest do
  # A sign-in on a fake Fermix app: `login_for`, the owner's answer through the
  # real `AccessGate.ask_in_call/3` on a store of this test's own, then
  # `sign_in`, all in the process that made the call. Every store and host is
  # this test's own, so it runs async.
  use ExUnit.Case, async: true

  alias FermixCore.Browser
  alias FermixCore.Browser.Capabilities
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.ProfileServer
  alias FermixCore.Browser.Scope
  alias FermixCore.Browser.SignIn
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Timeouts
  alias FermixTestSupport.FakeBrowserHostConnection

  @pane %{mode: :fermix_app, headless: :auto, cdp_port: :auto}

  # A backend that answers everything and reports what it was asked to do, so
  # what the server refuses on its own never reaches it.
  defmodule AskedBackend do
    @behaviour FermixCore.Browser.Backend

    @impl true
    def init(opts), do: %{test_pid: Keyword.fetch!(opts, :test_pid)}
    @impl true
    def status(_state), do: %{"running" => true, "tabs" => 0}
    @impl true
    def start(_context, state) do
      send(state.test_pid, :backend_started)
      {:ok, state}
    end

    @impl true
    def stop(state), do: state
    @impl true
    def handle_message(_message, state), do: state
    @impl true
    def console_buffer(_state), do: []

    for op <- ~w(open navigate snapshot tabs focus close screenshot pdf console dialog cookies
                 storage upload download act webmcp login_for sign_in)a do
      @impl true
      def unquote(op)(_args, _context, state) do
        send(state.test_pid, {:backend_asked, unquote(op)})
        {:ok, %{"ok" => true}, state}
      end
    end
  end

  # ── the call's arguments ─────────────────────────────────────────────────

  describe "the arguments" do
    test "a site is the canonical host name of a page" do
      assert SignIn.site("example.com") == {:ok, "example.com"}
      assert SignIn.site("Example.COM") == {:ok, "example.com"}
      assert SignIn.site("example.com.") == {:ok, "example.com"}
      assert SignIn.site("accounts.example.co.uk") == {:ok, "accounts.example.co.uk"}
      assert SignIn.site("my_host.example.com") == {:ok, "my_host.example.com"}
    end

    # Each refusal comes through the tool's own entry point, before any
    # browser, profile or owner is asked: the call never reaches a profile.
    test "an address, localhost, a dotless name, `%` and a fullwidth dot are refused" do
      for site <- [
            "127.0.0.1",
            "10.0.0.8",
            "127.1",
            "0x7f.1",
            "2130706433",
            "::1",
            "[::1]",
            "localhost",
            "localhost.",
            "app.localhost",
            "intranet",
            "exa%6dple.com",
            "example．com",
            "example..com",
            ".example.com",
            String.duplicate("a", 250) <> ".com"
          ] do
        assert {{:error, %Error{code: "sign_in_field", message: message}}, nil} =
                 execute(%{"site" => site, "password_ref" => "textbox_2"}),
               "#{inspect(site)} was not refused"

        assert message =~ "`site` must be the host name of the page in front of you"
        assert message =~ "Nothing was typed."
      end
    end

    test "a refused site never echoes characters a host name does not have" do
      assert {{:error, %Error{message: message}}, nil} =
               execute(%{"site" => "exa%6dple.com", "password_ref" => "textbox_2"})

      refute message =~ "%"
      assert message =~ "characters a host name does not"
    end

    test "a sign-in names at least one field, as a ref, and types no text of its own" do
      assert {{:error, %Error{code: "missing_arg", message: message}}, nil} =
               execute(%{"site" => "example.com"})

      assert message =~ "`username_ref`, `password_ref` or both"

      assert {{:error, %Error{code: "missing_arg"}}, nil} =
               execute(%{"username_ref" => "textbox_1"})

      assert {{:error, %Error{code: "invalid_arg"}}, nil} =
               execute(%{"site" => "example.com", "password_ref" => 12})

      assert {{:error, %Error{code: "invalid_arg", message: message}}, nil} =
               execute(%{"site" => "example.com", "password_ref" => "t", "text" => "pw"})

      assert message =~ "Never type a password yourself"

      assert SignIn.validate(%{"site" => "example.com", "username_ref" => "textbox_1"}) == :ok
      assert SignIn.validate(%{"site" => "example.com", "password_ref" => "textbox_2"}) == :ok
    end

    test "sign_in is an act kind, and never re-sent after a dead server" do
      assert Browser.mutating?("act", %{"kind" => "sign_in"})

      assert {{:error, %Error{code: "invalid_action", message: message}}, nil} =
               Browser.execute(%{"action" => "sign_in"}, context())

      assert message =~ ~s("action": "act", "kind": "sign_in")
    end
  end

  # ── which browser signs in ───────────────────────────────────────────────

  describe "the browsers" do
    test "only the Fermix app's pane signs in" do
      assert Capabilities.allows?(:fermix_app, :sign_in)

      for mode <- [:managed, :existing_session, :remote_cdp, :attached_tab] do
        refute Capabilities.allows?(mode, :sign_in), "#{mode} signs in"
      end
    end

    test "every other mode answers sign_in_pane_only before any host is asked" do
      test = self()
      route = fn request -> send(test, {:routed, request}) && {:ok, %{}} end

      for mode <- [:managed, :existing_session, :remote_cdp, :attached_tab] do
        assert {:error, %Error{code: "sign_in_pane_only", message: message}} =
                 SignIn.run(sign_in_args(), context(), mode, route)

        assert message =~ "only in the Fermix app's own browser"
        assert message =~ "Never ask the owner for the password"
      end

      refute_received {:routed, _request}
    end

    # The floor under `SignIn.run/4`: a profile that cannot sign in refuses
    # both halves before its backend is started, so no Chrome is launched for
    # a call it could never serve.
    test "a profile that cannot sign in refuses both halves before its backend starts" do
      {:ok, config} = Config.current(%{})

      pid =
        start_supervised!(
          {ProfileServer,
           owner_key: "owner-chrome",
           profile_name: "fermix_chrome",
           profile: %{@pane | mode: :managed},
           config: config,
           backend: AskedBackend,
           test_pid: self()},
          id: make_ref()
        )

      for action <- ~w(login_for sign_in) do
        assert {:error, %Error{code: "sign_in_pane_only"}} =
                 ProfileServer.request(pid, %{action: action, args: %{}, context: %{}})
      end

      refute_received :backend_started
      refute_received {:backend_asked, _op}
    end

    # The owner may take the whole approval window: the profile the two
    # requests run on must not idle out in between, or the tab is gone when
    # the answer comes. `HostServer` bounds `login_for` by the action timeout
    # and `sign_in` by it plus the app's 5 s keychain read and one settle.
    test "the profile outlives the owner's approval window and both requests" do
      config = %Config{}
      settle = Config.act_limits().settle_budget_ms
      requests = config.action_timeout_ms * 2 + 5_000 + settle

      assert config.idle_profile_ttl_ms > Timeouts.sign_in_approval() + requests
    end
  end

  # ── a sign-in on the app's pane ──────────────────────────────────────────

  describe "on the app's pane" do
    setup do
      pending = start_supervised!({Pending, name: nil}, id: make_ref())
      %{pending: pending}
    end

    test "a username alone is typed without asking the owner", ctx do
      {pid, connection} = pane(ctx)
      {:ok, opened} = open_login(pid)

      args = %{"site" => "example.com", "username_ref" => "textbox_1", "target" => opened}

      assert {:ok, result} = SignIn.run(args, chat(ctx), :fermix_app, route(pid))
      refute_received {:asked, _waiter, _id}

      assert result["ok"] == true
      assert result["action"] == "sign_in"
      assert result["target"] == opened
      assert result["site"] == "example.com"
      assert result["filled"] == ["username"]
      assert result["username"] == "person@example.com"
      refute Map.has_key?(result, "value")
      # The tab was looked at when it opened, so the fill looks again, as an
      # act does: the same page answers `unchanged`.
      assert result["page"] == "unchanged"

      assert [{"tab.open", _open}, {"page.login_for", lookup}, {"page.sign_in", typed}] =
               FakeBrowserHostConnection.requests(connection)

      assert lookup == %{"tab_id" => "t1", "site" => "example.com"}

      assert Map.drop(typed, ["snapshot"]) == %{
               "tab_id" => "t1",
               "site" => "example.com",
               "login_site" => "example.com",
               "username_ref" => 11,
               "observe" => true
             }
    end

    # A submit the facade sends next in the same call is the look the model
    # reads; a look at the filled form before it would cost the app a settle
    # and replace the refs the submit is sent with. So the app is asked not to
    # look, on a tab that was looked at, and the receipt carries no `page`.
    test "a sign-in a submit follows asks the app not to look at the page", ctx do
      {pid, connection} = pane(ctx)
      {:ok, opened} = open_login(pid)

      args = %{"site" => "example.com", "username_ref" => "textbox_1", "target" => opened}

      assert {:ok, result} = SignIn.run(args, chat(ctx), :fermix_app, route(pid), false)

      assert result["filled"] == ["username"]
      refute Map.has_key?(result, "page")

      assert [{"tab.open", _open}, {"page.login_for", _lookup}, {"page.sign_in", typed}] =
               FakeBrowserHostConnection.requests(connection)

      assert typed == %{
               "tab_id" => "t1",
               "site" => "example.com",
               "login_site" => "example.com",
               "username_ref" => 11,
               "observe" => false
             }
    end

    # `submit: true` sends the form only after a fill that succeeded, so a
    # sign-in the owner refuses, or never answers, types nothing and submits
    # nothing. Through the facade, which composes the submit.
    test "a sign-in with submit that the owner denies submits nothing", ctx do
      {turn, connection} = submitting_sign_in(ctx)

      assert_receive {:asked, _waiter, id}
      assert {:ok, :in_call} = AccessGate.deny(id, ctx.pending)

      assert {{:error, %Error{code: "sign_in_denied"}}, :fermix_app} = Task.await(turn)
      assert request_types(connection) == ["tab.open", "page.login_for"]
    end

    # The window's end is the waiter's own timer message, delivered by hand.
    @tag :capture_log
    test "a sign-in with submit that the owner never answers submits nothing", ctx do
      {turn, connection} = submitting_sign_in(ctx)

      assert_receive {:asked, waiter, id}
      send(waiter, {:access_timeout, id})

      assert {{:error, %Error{code: "sign_in_unanswered"}}, :fermix_app} = Task.await(turn)
      assert request_types(connection) == ["tab.open", "page.login_for"]
    end

    test "a page with no saved login is answered with where to add one, and nobody is asked",
         ctx do
      {pid, connection} = pane(ctx, no_login: true)
      {:ok, opened} = open_login(pid)

      assert {:error, %Error{code: "sign_in_no_login", message: message}} =
               SignIn.run(
                 Map.put(sign_in_args(), "target", opened),
                 chat(ctx),
                 :fermix_app,
                 route(pid)
               )

      assert message =~
               "No login is saved in the Fermix app for example.com or a site it is part of"

      assert message =~ "or for the site it is part of, in Settings > Browser > Website logins"
      assert message =~ "Never ask the owner for the password"
      refute_received {:asked, _waiter, _id}
      refute "page.sign_in" in request_types(connection)
    end

    test "a password is typed once the owner confirms, on the same task and tab", ctx do
      {pid, connection} = pane(ctx)
      {:ok, opened} = open_login(pid)
      turn = sign_in_turn(ctx, pid, Map.put(sign_in_args(), "target", opened))

      assert_receive {:asked, waiter, id}
      assert waiter == turn.pid
      assert_receive {:prompt, {:approval_prompt, text, "tok-1"}}
      assert text =~ "Sign in to example.com as person@example.com?"
      refute "page.sign_in" in request_types(connection)

      assert :ok = AccessGate.confirm_in_call(id, ctx.pending)
      assert {:ok, result} = Task.await(turn)

      assert result["filled"] == ["username", "password"]
      assert result["username"] == "person@example.com"
      assert result["target"] == opened

      assert [{"tab.open", open}, {"page.login_for", _lookup}, {"page.sign_in", typed}] =
               FakeBrowserHostConnection.requests(connection)

      # One tab was ever opened, and the fill went to it, on the task that
      # opened it: no release came between.
      assert open["url"] == "https://example.com/login"

      assert typed == %{
               "tab_id" => "t1",
               "site" => "example.com",
               "login_site" => "example.com",
               "username_ref" => 11,
               "password_ref" => 12,
               "observe" => true,
               "snapshot" => open["snapshot"]
             }

      assert FakeBrowserHostConnection.releases(connection) == []
    end

    test "the owner's no types nothing", ctx do
      {pid, connection} = pane(ctx)
      {:ok, opened} = open_login(pid)
      turn = sign_in_turn(ctx, pid, Map.put(sign_in_args(), "target", opened))

      assert_receive {:asked, _waiter, id}
      assert {:ok, :in_call} = AccessGate.deny(id, ctx.pending)

      assert {:error, %Error{code: "sign_in_denied", message: message}} = Task.await(turn)
      assert message =~ "The owner said no"
      refute "page.sign_in" in request_types(connection)
    end

    # The window's end is the waiter's own timer message, delivered here by
    # hand: no real clock is waited on.
    @tag :capture_log
    test "no answer within the window types nothing, and says the owner can be asked again",
         ctx do
      {pid, connection} = pane(ctx)
      {:ok, opened} = open_login(pid)
      turn = sign_in_turn(ctx, pid, Map.put(sign_in_args(), "target", opened))

      assert_receive {:asked, waiter, id}
      send(waiter, {:access_timeout, id})

      assert {:error, %Error{code: "sign_in_unanswered", message: message}} = Task.await(turn)
      assert message =~ "did not answer the sign-in question within 60 seconds"
      assert message =~ "ask again once they are back"
      refute "page.sign_in" in request_types(connection)
    end

    test "a turn with no surface to ask on types nothing, and says where to ask from", ctx do
      {pid, connection} = pane(ctx)
      {:ok, opened} = open_login(pid)
      context = Map.drop(chat(ctx), [:reply_fn, :approval_fn])

      assert {:error, %Error{code: "sign_in_not_delivered", message: message}} =
               SignIn.run(
                 Map.put(sign_in_args(), "target", opened),
                 context,
                 :fermix_app,
                 route(pid)
               )

      assert message =~ "could not put the sign-in question in front of the owner"
      assert message =~ "their own chat or the Fermix app"
      refute "page.sign_in" in request_types(connection)
    end

    # A site that signs in on a host of its own uses the login saved for the
    # domain it is under (the app's choice, M84 D2), and the owner is told both.
    test "a login saved for a parent domain is named beside the page's own host", ctx do
      {pid, _connection} = pane(ctx, login_site: "example.com", username: "person")
      {:ok, opened} = open_login(pid)

      args = %{sign_in_args() | "site" => "identity.example.com"} |> Map.put("target", opened)
      turn = sign_in_turn(ctx, pid, args)

      assert_receive {:asked, _waiter, id}
      assert_receive {:prompt, {:approval_prompt, text, _token}}

      assert text =~
               "Sign in to identity.example.com as person, with the login saved for example.com?"

      assert {:ok, :in_call} = AccessGate.deny(id, ctx.pending)
      assert {:error, %Error{code: "sign_in_denied"}} = Task.await(turn)
    end

    # The second form is the `www.` fold or a parent domain's login; every
    # value is shown escaped, so a username cannot forge a line of the owner's
    # prompt.
    test "the prompt names the page's site, the saved site and the username, escaped", ctx do
      {pid, _connection} = pane(ctx, login_site: "example.com", username: "person\nYes")
      {:ok, opened} = open_login(pid)

      args = %{sign_in_args() | "site" => "www.example.com"} |> Map.put("target", opened)
      turn = sign_in_turn(ctx, pid, args)

      assert_receive {:asked, _waiter, id}
      assert_receive {:prompt, {:approval_prompt, text, _token}}

      assert text =~
               "Sign in to www.example.com as person\\nYes, with the login saved for example.com?"

      refute text =~ "person\nYes"
      assert {:ok, :in_call} = AccessGate.deny(id, ctx.pending)
      assert {:error, %Error{code: "sign_in_denied"}} = Task.await(turn)
    end

    test "an app on protocol 1 is told it is too old, and is sent neither request", ctx do
      {pid, connection} = pane(ctx, protocol_version: 1)
      {:ok, opened} = open_login(pid)

      assert {:error, %Error{code: "sign_in_app_too_old", message: message}} =
               SignIn.run(
                 Map.put(sign_in_args(), "target", opened),
                 chat(ctx),
                 :fermix_app,
                 route(pid)
               )

      assert message =~ "update the Fermix app"
      assert request_types(connection) == ["tab.open"]
    end

    # The page checks answer the lookup; the rest answer the fill (a
    # username-only call, so nobody is asked first).
    test "the app's refusals reach the model as their own sentences", ctx do
      refusals = [
        {:refuse_lookup, "sign_in_insecure_page", "not served over https"},
        {:refuse_lookup, "sign_in_wrong_site", "call `sign_in` again with that host as `site`"},
        {:refuse, "sign_in_field", "`password_ref` must be the form's password input"},
        {:refuse, "sign_in_page_moved", "Take a snapshot and call `sign_in` again"},
        {:refuse, "sign_in_store_unavailable", "keychain (the keychain refused, OSStatus -25308)"}
      ]

      for {at, reason, sentence} <- refusals do
        {pid, connection} = pane(ctx, [{at, {reason, "the keychain refused, OSStatus -25308"}}])
        {:ok, opened} = open_login(pid)
        args = %{"site" => "example.com", "username_ref" => "textbox_1", "target" => opened}

        assert {:error, %Error{code: ^reason, message: message}} =
                 SignIn.run(args, chat(ctx), :fermix_app, route(pid))

        assert message =~ sentence, "#{reason}: #{message}"
        assert message =~ "nothing was typed"

        if at == :refuse_lookup, do: refute("page.sign_in" in request_types(connection))
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp execute(args) do
    Browser.execute(Map.merge(%{"action" => "act", "kind" => "sign_in"}, args), context())
  end

  defp context do
    %{
      agent_name: "t",
      source_trust: :operator,
      conversation_key: {"cli", "sign-in-#{System.unique_integer([:positive])}", :root}
    }
  end

  defp sign_in_args,
    do: %{"site" => "example.com", "username_ref" => "textbox_1", "password_ref" => "textbox_2"}

  # The owner's own chat: the approval closure reports the waiting process and
  # the record's id, the reply closure the prompt.
  defp chat(ctx) do
    test = self()

    %{
      agent_name: "t",
      session_id: "sign-in-#{System.unique_integer([:positive])}",
      source_trust: :operator,
      computer_use_origin: :interactive,
      conversation_key: {"telegram", "chat-1", :root},
      access_pending: ctx.pending,
      approval_fn: fn %{access_sensitive: id} ->
        send(test, {:asked, self(), id})
        {:ok, "tok-1", :new}
      end,
      reply_fn: fn part -> send(test, {:prompt, part}) end
    }
  end

  # The call runs in its own process, the turn, while this one is the owner.
  defp sign_in_turn(ctx, pid, args) do
    context = chat(ctx)
    Task.async(fn -> SignIn.run(args, context, :fermix_app, route(pid)) end)
  end

  defp route(pid), do: &ProfileServer.request(pid, &1)

  # A `browser` call that signs in and submits, made through the facade on a
  # pane registered for a conversation of its own, in the turn's own process.
  defp submitting_sign_in(ctx) do
    context = %{
      chat(ctx)
      | conversation_key: {"telegram", "sign-in-#{System.unique_integer([:positive])}", :root}
    }

    {pid, connection} = pane(ctx, routed_for: context)
    {:ok, opened} = open_login(pid)

    args =
      Map.merge(sign_in_args(), %{
        "action" => "act",
        "kind" => "sign_in",
        "target" => opened,
        "submit" => true
      })

    {Task.async(fn -> Browser.execute(args, context) end), connection}
  end

  defp request_types(connection),
    do: connection |> FakeBrowserHostConnection.requests() |> Enum.map(&elem(&1, 0))

  defp open_login(pid) do
    case ProfileServer.request(pid, %{
           action: "open",
           args: %{"url" => "https://example.com/login"},
           context: %{agent_name: "t"}
         }) do
      {:ok, %{"target" => target}} -> {:ok, target}
      other -> other
    end
  end

  # A pane on a fake app that answers a login page, its saved login, and the
  # fill; `opts` names the login, a page with none, a refusal, or the app's
  # protocol version.
  defp pane(_ctx, opts \\ []) do
    {:ok, connection} = FakeBrowserHostConnection.start_link(app_answers(opts))
    on_exit(fn -> Process.exit(connection, :kill) end)

    host = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    endpoint = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(endpoint, :kill) end)
    :ok = HostAvailability.listening(host, endpoint)
    :ok = HostAvailability.attached(host, connection, 1, Keyword.get(opts, :protocol_version, 2))
    :ok = HostAvailability.report(host, true, nil)

    {:ok, config} = Config.current(%{})

    server =
      [
        owner_key: "owner-sign-in-#{System.unique_integer([:positive])}",
        profile_name: "fermix",
        profile: @pane,
        config: config,
        host_availability: host
      ] ++ routed(Keyword.get(opts, :routed_for))

    pid = start_supervised!({ProfileServer, server}, id: make_ref())
    {pid, connection}
  end

  # Registered under a conversation's pane key, as `ProfileManager` would have
  # started it, so `Browser.execute/2` routes that conversation's calls to it.
  defp routed(nil), do: []

  defp routed(context) do
    {:ok, owner} = Scope.owner_key(context)
    pane = Scope.pane_key(owner, context.conversation_key)
    [registry: FermixCore.Browser.Registry, key: {pane, "fermix"}]
  end

  defp app_answers(opts) do
    login = %{
      "login_site" => Keyword.get(opts, :login_site, "example.com"),
      "username" => Keyword.get(opts, :username, "person@example.com")
    }

    %{
      "tab.open" =>
        {:ok,
         %{
           "tab_id" => "t1",
           "url" => "https://example.com/login",
           "title" => "Sign in",
           "page" => login_page()
         }},
      "page.login_for" => login_answer(opts, login),
      "page.sign_in" => sign_in_answer(opts)
    }
  end

  defp login_answer(opts, login) do
    cond do
      Keyword.get(opts, :no_login) ->
        {:error, %{"reason" => "sign_in_no_login", "message" => "no login for this site"}}

      refusal = Keyword.get(opts, :refuse_lookup) ->
        refused(refusal)

      true ->
        {:ok, login}
    end
  end

  defp sign_in_answer(opts) do
    case Keyword.get(opts, :refuse) do
      nil ->
        fn payload ->
          filled = Enum.filter(["username", "password"], &Map.has_key?(payload, &1 <> "_ref"))

          {:ok,
           %{
             "url" => "https://example.com/login",
             "title" => "Sign in",
             "filled" => filled,
             "page" => login_page()
           }}
        end

      refusal ->
        refused(refusal)
    end
  end

  defp refused({reason, message}), do: {:error, %{"reason" => reason, "message" => message}}

  defp login_page do
    %{
      "url" => "https://example.com/login",
      "title" => "Sign in",
      "ready_state" => "complete",
      "nodes" => [
        %{
          "nodeId" => "1",
          "role" => %{"value" => "RootWebArea"},
          "name" => %{"value" => "Sign in"},
          "childIds" => ["2", "3", "4"]
        },
        %{
          "nodeId" => "2",
          "backendDOMNodeId" => 11,
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Email"}
        },
        %{
          "nodeId" => "3",
          "backendDOMNodeId" => 12,
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Password"}
        },
        %{
          "nodeId" => "4",
          "backendDOMNodeId" => 13,
          "role" => %{"value" => "button"},
          "name" => %{"value" => "Sign in"}
        }
      ]
    }
  end
end
