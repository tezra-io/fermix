defmodule FermixCore.Computers.Capabilities.BrowserTest do
  # M97 §6.4: the browser of a computer, as an invocation carries it. Pure but
  # for `admit/3`, which reads the computer's browser from the invocation's
  # context: every value here is the test's own.
  use ExUnit.Case, async: true

  alias FermixCore.Browser
  alias FermixCore.Browser.Config
  alias FermixCore.Computers.Capabilities.Browser, as: BrowserCapability
  alias FermixCore.Computers.Capability
  alias FermixCore.Computers.Outcome
  alias FermixCore.Management.Copy

  @conversation "owner-Zm9yZXN0LXBhdGgtMTIz"

  # Every form a request takes: the tool's actions, an act's read and write
  # kinds, the read and write of cookies, storage and WebMCP, and a
  # sign-in's two halves.
  @forms [
    {"doctor", %{}},
    {"status", %{}},
    {"start", %{}},
    {"stop", %{}},
    {"open", %{"url" => "https://shop.example.com/cart?token=s3cret"}},
    {"navigate", %{"url" => "https://shop.example.com/orders"}},
    {"snapshot", %{}},
    {"tabs", %{}},
    {"focus", %{"target" => "t1"}},
    {"close", %{"target" => "t1"}},
    {"screenshot", %{}},
    {"pdf", %{}},
    {"console", %{}},
    {"dialog", %{"decision" => "accept"}},
    {"cookies", %{}},
    {"cookies", %{"kind" => "clear"}},
    {"storage", %{"key" => "cart"}},
    {"storage", %{"key" => "cart", "value" => "3"}},
    {"upload", %{"ref" => "button_3", "upload_name" => "receipt.pdf"}},
    {"download", %{}},
    {"act", %{"kind" => "click", "ref" => "button_1"}},
    {"act", %{"kind" => "fill", "ref" => "textbox_1", "text" => "Pat Rowe"}},
    {"act", %{"kind" => "get", "field" => "title"}},
    {"act", %{"kind" => "wait", "wait_until" => "load"}},
    {"webmcp", %{"op" => "list"}},
    {"webmcp", %{"op" => "call", "name" => "add_to_cart"}},
    {"handover", %{}},
    {"login_for", %{"site" => "shop.example.com", "target" => "t1"}},
    {"sign_in", %{"site" => "shop.example.com", "password_ref" => "textbox_2"}}
  ]

  defp request(action, args, more \\ %{}),
    do:
      Map.merge(
        %{"action" => action, "args" => args, "profile" => nil, "conversation" => @conversation},
        more
      )

  test "each request has its op, and changes something exactly as the browser says it does" do
    for {action, args} <- @forms do
      op = BrowserCapability.op(action, args)
      assert op in BrowserCapability.ops(), "#{action} #{inspect(args)}"
      assert Capability.op?(op)
      assert BrowserCapability.validate(op, request(action, args)) == :ok

      # A sign-in's second half is the act kind `sign_in`'s.
      mutating =
        if action == "sign_in",
          do: Browser.mutating?("act", %{"kind" => "sign_in"}),
          else: Browser.mutating?(action, args)

      assert BrowserCapability.effect?(op) == mutating, "#{op}"
    end

    assert BrowserCapability.op("act", %{"kind" => "get"}) == "browser.act.read"
    assert BrowserCapability.op("act", %{"kind" => "click"}) == "browser.act"
    assert BrowserCapability.op("webmcp", %{"op" => "call"}) == "browser.webmcp.call"
    refute BrowserCapability.effect?("browser.end")
  end

  test "a request whose op is not the one it is, or that names no conversation, is refused" do
    click = request("act", %{"kind" => "click", "ref" => "button_1"})
    assert {:error, _sentence} = BrowserCapability.validate("browser.act.read", click)

    assert {:error, _sentence} =
             BrowserCapability.validate("browser.act", Map.delete(click, "conversation"))

    assert {:error, _sentence} =
             BrowserCapability.validate("browser.act", %{click | "conversation" => "../x"})

    assert {:error, _sentence} = BrowserCapability.validate("browser.act", %{"action" => 3})
    assert {:error, _sentence} = BrowserCapability.validate("browser.end", %{"turn" => "maybe"})
    assert BrowserCapability.validate("browser.end", %{"turn" => "stopped"}) == :ok
  end

  test "an upload names its file by its name alone, never a path" do
    for name <- ["../secrets", "a/b.pdf", ".", "", nil] do
      args = %{"ref" => "button_3", "upload_name" => name}

      assert {:error, _sentence} =
               BrowserCapability.validate("browser.upload", request("upload", args))
    end

    with_path = %{"ref" => "button_3", "upload_name" => "a.pdf", "path" => "/etc/hosts"}

    assert {:error, _sentence} =
             BrowserCapability.validate("browser.upload", request("upload", with_path))
  end

  test "a target is a host or an action, never a page's address or content" do
    open = request("open", %{"url" => "https://shop.example.com/cart?token=s3cret"})
    assert BrowserCapability.target("browser.open", open) == "open shop.example.com"

    fill =
      request("act", %{"kind" => "fill", "ref" => "textbox_1", "text" => "Pat Rowe"}, %{
        "profile" => "fermix_chrome"
      })

    assert BrowserCapability.target("browser.act", fill) == "fermix_chrome: act fill"

    signing = request("sign_in", %{"site" => "shop.example.com", "password_ref" => "textbox_2"})
    assert BrowserCapability.target("browser.sign_in", signing) == "sign in shop.example.com"

    call = request("webmcp", %{"op" => "call", "name" => "add_to_cart"})
    assert BrowserCapability.target("browser.webmcp.call", call) == "webmcp call"

    for {action, args} <- @forms do
      op = BrowserCapability.op(action, args)
      target = BrowserCapability.target(op, request(action, args))
      refute target =~ "s3cret"
      refute target =~ "Pat Rowe"
      assert byte_size(target) <= Capability.max_target_bytes()
    end
  end

  test "every deadline is the op's own budget and a browser to start, within the link's most" do
    for {action, args} <- @forms do
      op = BrowserCapability.op(action, args)
      deadline = BrowserCapability.deadline_ms(op, request(action, args))
      assert deadline in 30_000..900_000, "#{op}: #{deadline}"
    end

    long = request("download", %{"timeout_ms" => 10_000_000})
    short = request("download", %{"timeout_ms" => 1_000})

    assert BrowserCapability.deadline_ms("browser.download", long) >
             BrowserCapability.deadline_ms("browser.download", short)

    assert BrowserCapability.deadline_ms("browser.end", %{"turn" => "ended"}) == 10_000
    assert BrowserCapability.bounds("browser.screenshot").part_bytes == Outcome.max_part_bytes()
  end

  defp context(seams, origin), do: %{id: "inv-1", origin: origin, browser: seams}

  describe "the computer's own rules" do
    setup do
      {:ok, config} = Config.current(%{launch_app: false}, engine_web_port: 4_101)
      seams = %{config: config, browser_dir: "/nowhere", uploads: "/nowhere", turns: %{}}
      %{seams: {:ok, seams}}
    end

    test "a sign-in only on a chat turn: never by voice, never unattended", %{seams: seams} do
      signing = request("sign_in", %{"site" => "shop.example.com", "password_ref" => "t"})
      looking = request("login_for", %{"site" => "shop.example.com"})

      for {op, args} <- [{"browser.sign_in", signing}, {"browser.login_for", looking}] do
        assert BrowserCapability.admit(op, args, context(seams, :chat)) == :ok

        assert {:refused, :unavailable, "A sign-in is approved in the chat, not by voice."} =
                 BrowserCapability.admit(op, args, context(seams, :voice))

        for origin <- [:scheduled, :cue, :worker, :background] do
          assert {:refused, :not_attended, _sentence} =
                   BrowserCapability.admit(op, args, context(seams, origin))
        end
      end
    end

    test "a granted tab and a hand-over only on a turn the owner is in", %{seams: seams} do
      granted = request("snapshot", %{}, %{"profile" => "selected_tab"})
      handing = request("handover", %{})

      for origin <- [:chat, :voice] do
        assert BrowserCapability.admit("browser.snapshot", granted, context(seams, origin)) == :ok
        assert BrowserCapability.admit("browser.handover", handing, context(seams, origin)) == :ok
      end

      for origin <- [:scheduled, :cue, :worker, :background] do
        assert {:refused, :not_attended, _sentence} =
                 BrowserCapability.admit("browser.snapshot", granted, context(seams, origin))

        assert {:refused, :not_attended, _sentence} =
                 BrowserCapability.admit("browser.handover", handing, context(seams, origin))
      end

      # The managed profile serves an unattended turn, as it does here.
      managed = request("snapshot", %{}, %{"profile" => "fermix_chrome"})

      assert BrowserCapability.admit("browser.snapshot", managed, context(seams, :scheduled)) ==
               :ok
    end

    test "every sentence the computer says obeys the copy rules", %{seams: seams} do
      signing = request("sign_in", %{"site" => "shop.example.com", "password_ref" => "t"})
      granted = request("snapshot", %{}, %{"profile" => "selected_tab"})

      refusals = [
        BrowserCapability.admit("browser.sign_in", signing, context(seams, :voice)),
        BrowserCapability.admit("browser.sign_in", signing, context(seams, :cue)),
        BrowserCapability.admit(
          "browser.handover",
          request("handover", %{}),
          context(seams, :cue)
        ),
        BrowserCapability.admit("browser.snapshot", granted, context(seams, :cue)),
        BrowserCapability.admit("browser.tabs", request("tabs", %{}), context(seams, :computer)),
        BrowserCapability.admit("browser.tabs", request("tabs", %{}), %{id: "i", origin: :chat})
      ]

      invalid = [
        BrowserCapability.validate("browser.end", %{}),
        BrowserCapability.validate("browser.act.read", request("act", %{"kind" => "click"})),
        BrowserCapability.validate("browser.tabs", %{request("tabs", %{}) | "conversation" => 3}),
        BrowserCapability.validate("browser.tabs", %{request("tabs", %{}) | "profile" => 3}),
        BrowserCapability.validate(
          "browser.upload",
          request("upload", %{"upload_name" => "a/b"})
        ),
        BrowserCapability.validate("browser.tabs", %{})
      ]

      sentences =
        for({:refused, _kind, sentence} <- refusals, do: sentence) ++
          for {:error, sentence} <- invalid, do: sentence

      assert length(sentences) == 12

      for sentence <- sentences do
        assert Copy.violations(sentence, :prose, []) == [], sentence
        assert String.ends_with?(sentence, "."), sentence
      end
    end

    test "a computer's own request, and a computer with no browser, are refused", %{seams: seams} do
      tabs = request("tabs", %{})

      assert {:refused, :unavailable, _sentence} =
               BrowserCapability.admit("browser.tabs", tabs, context(seams, :computer))

      assert {:refused, :unavailable, "This computer runs no browser for its server."} =
               BrowserCapability.admit("browser.tabs", tabs, %{id: "inv-1", origin: :chat})
    end
  end
end
