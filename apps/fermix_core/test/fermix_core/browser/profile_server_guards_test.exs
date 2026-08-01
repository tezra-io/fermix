defmodule FermixCore.Browser.ProfileServerGuardsTest do
  # Drives the three ProfileServer guards that stand between the model and the
  # host — the read gate on every page-read verb, upload containment, and the
  # download byte ceiling — through an injected fake CDP connection and a
  # throwaway FERMIX_HOME.
  #
  # async: false — FERMIX_HOME is process-global (it decides the workspace and
  # download directories the guards resolve against) and the fake connection
  # reports dispatched CDP commands to a registered collector.
  use ExUnit.Case, async: false

  alias FermixCore.Browser
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.ProfileServer
  alias FermixTestSupport.SafeRm

  # One fake page, parameterized by `"<mode>|<href>"` in its connect URL.
  # ProfileServer passes the profile's cdp_url straight to start_link/2, so this
  # is the seam that lets each test decide what the page reports — and, via
  # `mode`, how the live-URL read FAILS — without any shared mutable state
  # between servers.
  defmodule FakePage do
    use Agent

    alias FermixCore.Browser.Error

    def start_link("ws://fake/" <> spec, opts) do
      [mode, href] = String.split(spec, "|", parts: 2)
      Agent.start_link(fn -> %{mode: mode, href: href, owner: Keyword.get(opts, :owner)} end)
    end

    def close(pid), do: Agent.stop(pid)

    def command(pid, method, params, _session_id, _timeout_ms, _grace_ms) do
      page = Agent.get(pid, & &1)

      if collector = Process.whereis(:browser_guard_collector) do
        send(collector, {:cdp, page.owner, method, params})
      end

      run(page, method, params)
    end

    defp run(page, "Target.getTargets", _params) do
      {:ok,
       %{
         "targetInfos" => [
           %{"targetId" => "T1", "type" => "page", "url" => page.href, "title" => "Page"}
         ]
       }}
    end

    defp run(_page, "Target.attachToTarget", _params), do: {:ok, %{"sessionId" => "S1"}}
    defp run(_page, "Accessibility.getFullAXTree", _params), do: {:ok, %{"nodes" => ax_nodes()}}
    defp run(_page, "DOM.resolveNode", _params), do: {:ok, %{"object" => %{"objectId" => "OBJ1"}}}

    defp run(_page, "Page.captureScreenshot", _params),
      do: {:ok, %{"data" => Base.encode64("PNG-BYTES")}}

    defp run(_page, "Page.printToPDF", _params),
      do: {:ok, %{"data" => Base.encode64("%PDF-1.4")}}

    defp run(_page, "Network.getAllCookies", _params) do
      {:ok, %{"cookies" => [%{"name" => "sid", "domain" => "example.com", "value" => "SECRET"}]}}
    end

    # The live-meta read every read verb's gate hangs on.
    defp run(page, "Runtime.evaluate", %{expression: expression}) do
      if String.contains?(expression, "document.location.href") do
        live_meta(page)
      else
        {:ok, %{"result" => %{"value" => nil}}}
      end
    end

    defp run(_page, _method, _params), do: {:ok, %{}}

    defp live_meta(%{mode: "live", href: href}) do
      {:ok,
       %{"result" => %{"value" => %{"url" => href, "title" => "Page", "ready" => "complete"}}}}
    end

    # What Chrome answers in the moments right after a commit; an action-timeout
    # expiry arrives in the same `{:error, _}` shape.
    defp live_meta(%{mode: "evaluate_error"}) do
      {:error, Error.new("cdp_error", "Execution context was destroyed.")}
    end

    # What a hostile page gets by throwing out of the expression —
    # `document.title` is a configurable accessor, so a getter trap on it makes
    # the whole thing throw and the result carries no "url" key.
    defp live_meta(%{mode: "malformed"}) do
      {:ok,
       %{
         "result" => %{"description" => "Uncaught 0"},
         "exceptionDetails" => %{"text" => "Uncaught"}
       }}
    end

    defp ax_nodes do
      [
        %{"nodeId" => "1", "role" => %{"value" => "RootWebArea"}, "childIds" => ["2"]},
        %{
          "nodeId" => "2",
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Where to?"},
          "backendDOMNodeId" => 42,
          "childIds" => []
        }
      ]
    end
  end

  defmodule NoLauncher do
    def attach(_config, _profile, _owner, _name), do: :none
    def start(_config, _profile, _owner, _name), do: {:error, :unused}
    def stop(_runtime, _config), do: :ok
  end

  @owner "owner-guards"

  setup do
    Process.register(self(), :browser_guard_collector)

    # A throwaway FERMIX_HOME: the workspace root the upload guard confines to
    # and the download directory the byte ceiling deletes from both hang off it,
    # so nothing here can reach the operator's real ~/.fermix.
    home = SafeRm.make_tmp_dir!("browser-guards")
    workspace = Path.join(home, "workspace")
    File.mkdir_p!(workspace)

    previous_home = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      restore_home(previous_home)

      if Process.whereis(:browser_guard_collector) do
        Process.unregister(:browser_guard_collector)
      end

      SafeRm.rm_rf!(home)
    end)

    %{home: home, workspace: workspace}
  end

  defp start_page(href, config, id), do: start_page(href, config, id, "live")

  defp start_page(href, config, id, mode) do
    start_supervised!(
      {ProfileServer,
       owner_key: @owner,
       profile_name: "fermix",
       profile: %{cdp_url: "ws://fake/" <> mode <> "|" <> href},
       config: config,
       launcher: NoLauncher,
       connection: FakePage},
      id: id
    )
  end

  defp req(pid, action, args \\ %{}),
    do: ProfileServer.request(pid, %{action: action, args: args, context: %{agent_name: "t"}})

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)

  defp public_config do
    # Establish the shipped posture explicitly rather than inheriting it: these
    # guards only mean something with allow_private_network: false.
    {:ok, config} = Config.current(allow_private_network: false)
    config
  end

  # ── the read-path invariant (finding 18) ───────────────────────────────────

  # Every advertised action that does NOT return bytes read from a page, with
  # the reason it is out of scope. The invariant test below walks
  # `FermixCore.Browser.actions/0` — the same list the tool's schema enum is
  # built from — and requires everything absent from this map to refuse. So a
  # verb added later either joins the invariant or fails this test; it cannot
  # quietly become a sixth bypass the way `act get`, `screenshot`, `pdf`,
  # `cookies` and `storage` did when the gate lived inside `snapshot` alone.
  @no_page_read %{
    "doctor" => "chrome discovery; never reaches a profile or a page",
    "status" => "profile liveness counters; reads no page",
    "start" => "lifecycle; reads no page",
    "stop" => "lifecycle; reads no page",
    "open" => "a navigation — Policy.validate_url/2 refuses the destination first",
    "navigate" => "a navigation — pre-checked, then re-checked on the committed URL",
    "tabs" =>
      "the tab inventory; refusing it would hide the blocked tab and leave no id to close",
    "focus" => "activates a tab; returns no page bytes",
    "close" => "closes a tab; must stay reachable so the blocked tab can be disposed of",
    "console" => "browser-scoped event buffer, not a read of the addressed tab",
    "dialog" => "answers or lists a JS dialog; needed to unblock a stuck page",
    "upload" => "a write into a file input; confined by confined_upload_path/1 instead",
    "download" => "returns a file Chrome fetched; bounded by the byte ceiling, not the tab URL",
    "act" => "one action, nine kinds — driven kind by kind in the next test"
  }

  test "NO read verb returns content once the live URL is a private host" do
    pid = start_page("http://169.254.169.254/latest/meta-data/", public_config(), :guards_surface)
    assert {:ok, _} = req(pid, "start")

    read_verbs = Enum.reject(Browser.actions(), &Map.has_key?(@no_page_read, &1))
    refute read_verbs == [], "every action was exempted — the invariant would be vacuous"

    for action <- read_verbs do
      result = req(pid, action)

      assert match?({:error, %Error{code: "read_blocked"}}, result),
             "`#{action}` did not refuse a policy-blocked URL: #{inspect(result)}"
    end
  end

  # `act`'s kinds mirror the private `@act_kinds` in `FermixCore.Browser`, which
  # is not enumerable from here — so the split is declared. The `refute ... =~
  # "Unsupported act kind"` below pins it against a rename or removal; a kind
  # ADDED upstream is the one drift this cannot see.
  @page_read_kinds %{
    "get html" => %{"kind" => "get", "field" => "html"},
    "get text" => %{"kind" => "get", "field" => "text"},
    "get rect" => %{"kind" => "get", "field" => "rect", "selector" => "canvas"},
    "wait text" => %{"kind" => "wait", "wait_until" => "text", "text" => "ami-"},
    "wait url" => %{"kind" => "wait", "wait_until" => "url", "text" => "meta-data"},
    "wait load" => %{"kind" => "wait", "wait_until" => "load"},
    "wait element" => %{"kind" => "wait", "wait_until" => "element", "selector" => "body"},
    "wait element ref" => %{"kind" => "wait", "wait_until" => "element", "ref" => "textbox_1"}
  }

  test "NO act kind returns page content once the live URL is a private host" do
    pid = start_page("http://169.254.169.254/latest/meta-data/", public_config(), :guards_kinds)
    assert {:ok, _} = req(pid, "start")

    for {label, args} <- @page_read_kinds do
      result = req(pid, "act", Map.put(args, "timeout_ms", 50))

      refute match?({:error, %Error{message: "Unsupported act kind" <> _}}, result),
             "`act #{label}` is no longer a real act kind"

      assert match?({:error, %Error{code: "read_blocked"}}, result),
             "`act #{label}` did not refuse a policy-blocked URL: #{inspect(result)}"
    end
  end

  # The gate must not over-block: the same verbs still serve an allowed page.
  test "every read verb still returns content for a page the policy allows" do
    pid = start_page("https://example.com/results", public_config(), :guards_allowed)
    assert {:ok, _} = req(pid, "start")

    assert {:ok, %{"url" => "https://example.com/results"}} = req(pid, "snapshot")
    assert {:ok, %{"mime_type" => "image/png"}} = req(pid, "screenshot")
    assert {:ok, %{"mime_type" => "application/pdf"}} = req(pid, "pdf")
    assert {:ok, %{"cookies" => [%{"name" => "sid"}]}} = req(pid, "cookies")
    assert {:ok, %{"ok" => true}} = req(pid, "storage")
    assert {:ok, %{"ok" => true}} = req(pid, "act", %{"kind" => "get", "field" => "html"})
  end

  test "snapshot refuses a page that ended up on a .internal name" do
    pid =
      start_page("http://metadata.google.internal/computeMetadata/", public_config(), :guards_int)

    assert {:ok, _} = req(pid, "start")
    assert {:error, %Error{code: "read_blocked"} = error} = req(pid, "snapshot")
    assert error.details["value"] == "metadata.google.internal"
  end

  # ── the gate must not fail open when its input is missing ──────────────────

  # The cached Target.getTargets url here is the ALLOWED one the tab was opened
  # with; only the LIVE read fails. Handing the gate that stale url is what let
  # a page through by committing to a private host and then killing the
  # execution context — routine right after a commit, and identical in shape to
  # an action-timeout expiry.
  test "a read refuses when the live URL cannot be read at all" do
    pid =
      start_page(
        "https://example.com/allowed",
        public_config(),
        :guards_live_err,
        "evaluate_error"
      )

    assert {:ok, _} = req(pid, "start")

    assert {:error, %Error{code: "read_url_unavailable"} = error} = req(pid, "snapshot")
    assert error.details["reason"] =~ "Execution context was destroyed"

    assert {:error, %Error{code: "read_url_unavailable"}} =
             req(pid, "act", %{"kind" => "get", "field" => "html"})

    assert {:error, %Error{code: "read_url_unavailable"}} = req(pid, "screenshot")
  end

  # The other half: the evaluate SUCCEEDS but its result carries no "url".
  # `Object.defineProperty(document, 'title', {get(){throw 0}})` is enough — the
  # whole expression throws and the gate is handed a description string.
  test "a read refuses when the live-URL read comes back without a url" do
    pid =
      start_page("https://example.com/allowed", public_config(), :guards_live_bad, "malformed")

    assert {:ok, _} = req(pid, "start")

    assert {:error, %Error{code: "read_url_unavailable"} = error} = req(pid, "snapshot")
    assert error.details["reason"] =~ "Uncaught 0"
  end

  # Unreachable-live-URL and blocked-URL stay distinct: one is retryable, the
  # other is a policy verdict, and a model that cannot tell them apart retries
  # into the wall or gives up on a page that was merely mid-navigation.
  test "an unreadable live URL and a blocked live URL are different failures" do
    unreadable =
      start_page("https://example.com/a", public_config(), :guards_kind_a, "evaluate_error")

    blocked = start_page("http://169.254.169.254/", public_config(), :guards_kind_b)

    assert {:ok, _} = req(unreadable, "start")
    assert {:ok, _} = req(blocked, "start")

    assert {:error, %Error{code: "read_url_unavailable"}} = req(unreadable, "snapshot")
    assert {:error, %Error{code: "read_blocked"}} = req(blocked, "snapshot")
  end

  # ── the gate is scoped to the private-address question ─────────────────────

  # A page that commits to a `blob:` URL is the ordinary in-page PDF/print-
  # preview pattern. Reusing the NAVIGATION policy wholesale refused it with
  # "Unsupported URL scheme: blob" — a new false-refusal class, described in the
  # words of an action the model never took.
  test "a blob: document reads normally — its ORIGIN is what is judged" do
    pid = start_page("blob:https://example.com/9d1a-3f", public_config(), :guards_blob_ok)

    assert {:ok, _} = req(pid, "start")
    assert {:ok, %{"url" => "blob:https://example.com/9d1a-3f"}} = req(pid, "snapshot")
  end

  # Unwrapping that origin is not a bypass: a blob minted by a private page
  # still names the private host.
  test "a blob: document minted by a private host is still refused" do
    pid = start_page("blob:http://169.254.169.254/9d1a-3f", public_config(), :guards_blob_bad)

    assert {:ok, _} = req(pid, "start")
    assert {:error, %Error{code: "read_blocked"} = error} = req(pid, "snapshot")
    assert error.details["value"] == "169.254.169.254"
  end

  # `URI.parse/1` strips the brackets off an IPv6 authority, so the gate has to
  # put them back before re-validating the host — otherwise the metadata address
  # in its IPv4-mapped form is judged as something else entirely.
  test "an IPv4-in-IPv6 metadata host is refused as the address it embeds" do
    pid = start_page("http://[::ffff:169.254.169.254]/latest/", public_config(), :guards_ipv6)

    assert {:ok, _} = req(pid, "start")
    assert {:error, %Error{code: "read_blocked"} = error} = req(pid, "snapshot")
    assert error.details["value"] == "::ffff:169.254.169.254"
    assert error.message =~ "private network"
  end

  # ── upload containment (finding 12) ────────────────────────────────────────

  # Both sides of the containment compare are resolved, so a symlink cannot make
  # an outside file look like an inside one. The two shapes below are the two
  # halves a purely lexical Path.expand missed.
  test "upload refuses a symlinked FINAL component pointing outside the workspace", %{
    home: home,
    workspace: workspace
  } do
    outside = Path.join(home, "outside")
    File.mkdir_p!(outside)
    secret = Path.join(outside, "secret.txt")
    File.write!(secret, "not yours")

    link = Path.join(workspace, "innocent.txt")
    File.ln_s!(secret, link)

    pid = start_page("https://example.com", public_config(), :guards_upload_final)
    ready(pid)

    assert {:error, %Error{code: "upload_blocked"}} =
             req(pid, "upload", %{"path" => link, "ref" => "textbox_1"})
  end

  test "upload refuses a symlinked INTERMEDIATE directory", %{
    home: home,
    workspace: workspace
  } do
    outside = Path.join(home, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "not yours")

    File.ln_s!(outside, Path.join(workspace, "docs"))

    pid = start_page("https://example.com", public_config(), :guards_upload_dir)
    ready(pid)

    assert {:error, %Error{code: "upload_blocked"}} =
             req(pid, "upload", %{
               "path" => Path.join([workspace, "docs", "secret.txt"]),
               "ref" => "textbox_1"
             })
  end

  # The containment must not over-block: a real file inside the workspace still
  # uploads. This is also what proves BOTH sides are canonicalized — on macOS the
  # tmp workspace lives under /var, a symlink to /private/var, so resolving only
  # the argument would push every legitimate upload outside the root.
  test "upload accepts a real file inside the workspace", %{workspace: workspace} do
    path = Path.join(workspace, "report.csv")
    File.write!(path, "a,b\n1,2\n")

    pid = start_page("https://example.com", public_config(), :guards_upload_ok)
    ready(pid)

    assert {:ok, %{"uploaded" => "report.csv"}} =
             req(pid, "upload", %{"path" => path, "ref" => "textbox_1"})

    assert_receive {:cdp, _owner, "DOM.setFileInputFiles", %{files: [uploaded]}}
    assert File.regular?(uploaded)
  end

  # ── download byte ceiling (finding 51) ─────────────────────────────────────

  test "an oversized download is canceled, its partial deleted, and the waiter told why" do
    {:ok, config} = Config.current(allow_private_network: false, download_max_bytes: 1_000)
    pid = start_page("https://example.com", config, :guards_download_big)
    assert {:ok, _} = req(pid, "start")

    partial = download_path("G1")
    File.mkdir_p!(Path.dirname(partial))
    File.write!(partial, :binary.copy("x", 2_000))

    begin_download(pid, "G1", "https://example.com/huge.iso", "huge.iso")
    progress(pid, "G1", "inProgress", 2_000, 9_000_000)

    assert_receive {:cdp, _owner, "Browser.cancelDownload", %{guid: "G1"}}
    refute File.exists?(partial)

    assert {:error, %Error{code: "download_too_large"} = error} =
             req(pid, "download", %{"timeout_ms" => 50})

    assert error.details["guid"] == "G1"
    assert error.details["received_bytes"] == 2_000

    # Reported exactly once: a refusal that replayed forever would make every
    # later download in this profile impossible.
    assert {:error, %Error{code: "timeout"}} = req(pid, "download", %{"timeout_ms" => 50})
  end

  # The cancel itself must be ONE-SHOT. Chrome keeps emitting inProgress ticks
  # for a download it has been told to cancel, and the idempotence guard used to
  # key on "state" — which `merge_download_progress/2` rewrites from the CDP
  # params on every tick, so it could never match. Each tick then re-entered the
  # cancel path: a BLOCKING CDP command issued from inside `handle_info/2` plus
  # another `File.rm`. MORE THAN ONE tick past the cap is the whole test.
  test "an oversized download is canceled exactly once, however many ticks follow" do
    {:ok, config} = Config.current(allow_private_network: false, download_max_bytes: 1_000)
    pid = start_page("https://example.com", config, :guards_download_once)
    assert {:ok, _} = req(pid, "start")

    begin_download(pid, "G4", "https://example.com/huge.iso", "huge.iso")
    progress(pid, "G4", "inProgress", 2_000, 9_000_000)
    assert_receive {:cdp, _owner, "Browser.cancelDownload", %{guid: "G4"}}

    progress(pid, "G4", "inProgress", 3_000, 9_000_000)
    progress(pid, "G4", "inProgress", 4_000, 9_000_000)

    refute_receive {:cdp, _owner, "Browser.cancelDownload", _params}, 200

    # Still exactly one verdict for the waiter, and still only one.
    assert {:error, %Error{code: "download_too_large"}} =
             req(pid, "download", %{"timeout_ms" => 50})

    assert {:error, %Error{code: "timeout"}} = req(pid, "download", %{"timeout_ms" => 50})
  end

  # A download whose DECLARED size is over the ceiling is refused before the
  # bytes land, not after.
  test "a declared-oversize download is canceled on the first progress event" do
    {:ok, config} = Config.current(allow_private_network: false, download_max_bytes: 1_000)
    pid = start_page("https://example.com", config, :guards_download_declared)
    assert {:ok, _} = req(pid, "start")

    begin_download(pid, "G2", "https://example.com/huge.iso", "huge.iso")
    progress(pid, "G2", "inProgress", 12, 5_000)

    assert_receive {:cdp, _owner, "Browser.cancelDownload", %{guid: "G2"}}

    assert {:error, %Error{code: "download_too_large"}} =
             req(pid, "download", %{"timeout_ms" => 50})
  end

  test "a download under the ceiling completes and is reported normally" do
    {:ok, config} = Config.current(allow_private_network: false, download_max_bytes: 1_000)
    pid = start_page("https://example.com", config, :guards_download_small)
    assert {:ok, _} = req(pid, "start")

    begin_download(pid, "G3", "https://example.com/small.csv", "small.csv")
    progress(pid, "G3", "completed", 120, 120)

    assert {:ok, %{"guid" => "G3", "suggested_filename" => "small.csv"}} =
             req(pid, "download", %{"timeout_ms" => 500})

    refute_receive {:cdp, _owner, "Browser.cancelDownload", _params}, 50
  end

  defp download_path(guid) do
    Path.join([System.get_env("FERMIX_HOME"), "browser", "downloads", @owner, guid])
  end

  defp begin_download(pid, guid, url, filename) do
    send(
      pid,
      {:cdp_event, "Browser.downloadWillBegin",
       %{"params" => %{"guid" => guid, "url" => url, "suggestedFilename" => filename}}}
    )
  end

  defp progress(pid, guid, state, received, total) do
    send(
      pid,
      {:cdp_event, "Browser.downloadProgress",
       %{
         "params" => %{
           "guid" => guid,
           "state" => state,
           "receivedBytes" => received,
           "totalBytes" => total
         }
       }}
    )
  end

  # Refs belong to the snapshot they came from, so upload needs one first.
  defp ready(pid) do
    assert {:ok, _} = req(pid, "start")
    assert {:ok, _} = req(pid, "snapshot")
    flush_cdp()
  end

  defp flush_cdp do
    receive do
      {:cdp, _owner, _method, _params} -> flush_cdp()
    after
      0 -> :ok
    end
  end
end
