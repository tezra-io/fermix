defmodule Fermix.CLI.BrowserHandoffCommandTest do
  # `fermix browser signin|handoff|handoffs` over a stand-in management
  # client. Sync: the verbs print refusals on `:standard_error`, one globally
  # registered device that concurrent captures would share.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.BrowserCommand
  alias Fermix.CLI.BrowserHandoffCommand
  alias Fermix.CLI.MachineOutput

  @home "/invented/fermix-home"

  defp run(argv, client) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out =
          capture_io(fn ->
            send(parent, {:status, BrowserCommand.run(argv, home: @home, client: client)})
          end)

        send(parent, {:out, out})
      end)

    assert_received {:status, status}
    assert_received {:out, out}
    {status, out, err}
  end

  defp answering(test, result) do
    fn method, params, opts ->
      assert Keyword.fetch!(opts, :socket_path) == Path.join(@home, "daemon.sock")
      send(test, {:called, method, params})
      {:ok, result}
    end
  end

  test "signin opens the address and prints the engine's sentence, then the hand-off verb" do
    client = answering(self(), %{"sentence" => "Chrome is open on the Fermix profile."})

    assert {0,
            "Chrome is open on the Fermix profile.\nThen run: fermix browser handoff SITE...\n",
            ""} = run(["signin", "https://news.example.org/login"], client)

    assert_received {:called, "browser.signin.open", %{"url" => "https://news.example.org/login"}}
  end

  test "handoff sends the sites, the expiry and the flag, and --json prints the result unchanged" do
    result = %{
      "handoff_id" => "ho-1",
      "sites" => [%{"site" => "news.example.org", "cookies" => 3}],
      "cookies_sent" => 3,
      "cookies_stored" => 3,
      "expires_at" => "2026-11-03T09:00:00Z",
      "sentence" => "The server stored 3 of the 3 cookies, until 2026-11-03 09:00 UTC."
    }

    {0, out, ""} =
      run(
        [
          "handoff",
          "news.example.org",
          "--expires",
          "12h",
          "--allow-identity-provider",
          "--json"
        ],
        answering(self(), result)
      )

    assert Jason.decode!(out) == %{"schema_version" => 1, "ok" => true, "result" => result}

    assert_received {:called, "browser.handoff.send",
                     %{
                       "sites" => ["news.example.org"],
                       "expires_s" => 43_200,
                       "allow_identity_provider" => true
                     }}

    {0, human, ""} = run(["handoff", "news.example.org"], answering(self(), result))
    assert human =~ "news.example.org: 3 cookies"
    assert human =~ "The server stored 3 of the 3 cookies"
    assert_received {:called, "browser.handoff.send", params}
    refute Map.has_key?(params, "expires_s")
  end

  test "handoffs lists, and wipe names its sites or none" do
    list = %{
      "handoffs" => [
        %{
          "handoff_id" => "ho-1",
          "from" => "Studio Mac",
          "sites" => ["news.example.org"],
          "cookies" => 3,
          "stored_at" => "2026-10-27T09:00:00Z",
          "expires_at" => "2026-11-03T09:00:00Z",
          "expired" => false
        }
      ],
      "sentence" => "One hand-off is stored here."
    }

    {0, out, ""} = run(["handoffs"], answering(self(), list))
    assert out =~ "One hand-off is stored here."
    assert out =~ "news.example.org: 3 cookies from Studio Mac, until 2026-11-03T09:00:00Z"
    assert_received {:called, "browser.handoffs.list", %{}}

    # On a desktop too, the answer is the count the server deleted (G6).
    wiped = %{
      "sites" => nil,
      "cookies" => 2,
      "sentence" => "Every hand-off is wiped: 2 cookies deleted."
    }

    {0, out, ""} = run(["handoffs", "wipe"], answering(self(), wiped))
    assert out == "Every hand-off is wiped: 2 cookies deleted.\n"
    assert_received {:called, "browser.handoffs.wipe", %{}}

    {0, _out, ""} = run(["handoffs", "wipe", "news.example.org"], answering(self(), wiped))
    assert_received {:called, "browser.handoffs.wipe", %{"sites" => ["news.example.org"]}}
  end

  test "a refusal is the engine's sentence; a stopped engine is named" do
    refusing = fn _method, _params, _opts ->
      {:error,
       {:management_error, "invalid_params", "Invalid parameters.",
        %{"field" => "sites", "sentence" => "accounts.google.com signs you in to other sites."}}}
    end

    {1, out, ""} = run(["handoff", "accounts.google.com", "--json"], refusing)

    assert Jason.decode!(out)["error"] == %{
             "code" => "browser_refused",
             "sentence" =>
               "Fermix did not do that in the browser. It said: accounts.google.com signs you in to other sites."
           }

    {1, "", err} = run(["handoffs"], fn _m, _p, _o -> {:error, :not_running} end)
    assert err =~ MachineOutput.sentence(:engine_stopped, [])
  end

  test "argv it does not understand is a usage error with no envelope" do
    client = fn _method, _params, _opts -> flunk("nothing is called") end

    for argv <- [
          ["signin"],
          ["signin", "https://a.example", "https://b.example"],
          ["handoff"],
          ["handoff", "a.example", "--expires", "7 days"],
          ["handoff", "a.example", "--expires", "0d"],
          ["handoffs", "list"]
        ] do
      assert {2, "", err} = run(argv, client), inspect(argv)
      assert err =~ "Usage"
    end
  end

  test "a duration is a whole number of days, hours or minutes" do
    assert BrowserHandoffCommand.duration("7d") == {:ok, 604_800}
    assert BrowserHandoffCommand.duration("12h") == {:ok, 43_200}
    assert BrowserHandoffCommand.duration("90m") == {:ok, 5_400}
    assert BrowserHandoffCommand.duration("1w") == :error
    assert BrowserHandoffCommand.duration("-1d") == :error
  end
end
