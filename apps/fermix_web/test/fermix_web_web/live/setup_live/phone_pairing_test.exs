defmodule FermixWebWeb.SetupLive.PhonePairingTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Protocol
  alias FermixWebWeb.SetupLive.PhonePairing
  alias FermixWebWeb.SetupLive.PhonePairing.Link

  @link "fermix://pair?v=2&k=c2VjcmV0&h=192.0.2.10:4031"

  defp status(overrides \\ %{}) do
    Map.merge(
      %{
        "enabled" => true,
        "started" => true,
        "refused" => false,
        "listener" => %{"status" => "ready"},
        "paired_devices" => 0,
        "remote" => %{"state" => "off", "connected" => false, "failure" => nil},
        "pairing" => nil
      },
      overrides
    )
  end

  defp view(state, overrides \\ %{}) do
    Map.merge(
      %{
        "session_id" => "s1",
        "state" => state,
        "ttl_ms" => 90_000,
        "request" => nil,
        "outcome" => nil,
        "failure" => nil
      },
      overrides
    )
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        "device_name" => "Rowan's Pixel",
        "model" => "Pixel 9",
        "sas" => "481062",
        "attestation" => %{
          "status" => "verified",
          "sentence" => "Secure hardware, locked bootloader, official Fermix build."
        }
      },
      overrides
    )
  end

  defp scan_step, do: {:scan, %{session: "s1", link: %Link{text: @link}, ttl_ms: 90_000}}

  defp compare_step do
    {:compare,
     %{
       session: "s1",
       device_name: "Rowan's Pixel",
       model: "Pixel 9",
       digits: "481062",
       hardware: "Secure hardware, locked bootloader, official Fermix build.",
       ttl_ms: 60_000
     }}
  end

  describe "the pairing link" do
    test "never prints its text" do
      link = %Link{text: @link}

      assert inspect(link) == "#PairingLink<withheld>"
      refute inspect(%{step: {:scan, %{link: link}}}) =~ "fermix://"
    end
  end

  describe "opening" do
    test "a channel that runs goes straight to opening the window" do
      assert PhonePairing.reduce(:closed, {:status, status()}) == {{:waiting, nil}, nil}
    end

    test "a channel that is off is turned on first" do
      off = status(%{"enabled" => false, "started" => false})
      {step, nil} = PhonePairing.reduce(:closed, {:status, off})

      assert step == {:turn_on, %{action: :switch_on, refusal: nil}}
    end

    test "a channel that is on but not running owes a restart" do
      {step, nil} = PhonePairing.reduce(:closed, {:status, status(%{"started" => false})})

      assert {:turn_on, %{action: :restart}} = step
    end
  end

  describe "the start" do
    test "an open window shows its code and keeps the link" do
      answer = {:started, Map.put(view("awaiting_scan"), "uri", @link)}

      assert {{:scan, %{session: "s1", link: %Link{text: @link}, ttl_ms: 90_000}}, nil} =
               PhonePairing.reduce({:waiting, nil}, answer)
    end

    test "a refused start ends with the daemon's sentence" do
      failed =
        view("failed", %{
          "session_id" => nil,
          "ttl_ms" => nil,
          "uri" => nil,
          "failure" => %{
            "code" => "unavailable",
            "sentence" => "The mobile channel is turned off."
          }
        })

      assert {{:ended, %{sentence: "The mobile channel is turned off.", action: :pair_again}},
              nil} = PhonePairing.reduce({:waiting, nil}, {:started, failed})
    end

    for {name, uri} <- [
          {"another scheme", "https://example.test/pair?v=2"},
          {"a control character", "fermix://pair?v=2\nk=x"},
          {"an oversized link", "fermix://pair?" <> String.duplicate("a", 2_048)},
          {"no link", nil}
        ] do
      test "a start with #{name} is unreadable and cancels its window" do
        answer = {:started, Map.put(view("awaiting_scan"), "uri", unquote(uri))}

        assert {{:ended, %{sentence: sentence, action: :pair_again}}, "s1"} =
                 PhonePairing.reduce({:waiting, nil}, answer)

        assert sentence == PhonePairing.unreadable_sentence()
      end
    end

    for ttl <- [0, -1, 120_001, nil] do
      test "a start whose window lasts #{inspect(ttl)} ms is unreadable" do
        answer = {:started, view("awaiting_scan", %{"ttl_ms" => unquote(ttl), "uri" => @link})}

        assert {{:ended, _ending}, "s1"} = PhonePairing.reduce({:waiting, nil}, answer)
      end
    end
  end

  describe "busy" do
    test "a phone waiting for a decision elsewhere is resumed here" do
      summary = %{"session_id" => "s9", "state" => "awaiting_decision"}

      assert PhonePairing.reduce({:waiting, nil}, {:busy, summary}) == {{:waiting, "s9"}, nil}
    end

    test "a code waiting for a scan elsewhere offers to start over" do
      summary = %{"session_id" => "s9", "state" => "awaiting_scan"}

      assert {{:ended, %{sentence: sentence, action: {:start_over, "s9"}}}, nil} =
               PhonePairing.reduce({:waiting, nil}, {:busy, summary})

      assert sentence == "A pairing code is already open somewhere else."
    end

    test "a window nobody names still offers to start over" do
      assert {{:ended, %{action: {:start_over, nil}}}, nil} =
               PhonePairing.reduce({:waiting, nil}, {:busy, nil})
    end
  end

  describe "reading a window" do
    test "a scan read moves the countdown and keeps the link" do
      {step, nil} =
        PhonePairing.reduce(scan_step(), {:session, view("awaiting_scan", %{"ttl_ms" => 30_000})})

      assert {:scan, %{ttl_ms: 30_000, link: %Link{text: @link}}} = step
    end

    test "a read of another window changes nothing" do
      other = view("approved", %{"session_id" => "s2"})

      assert PhonePairing.reduce(scan_step(), {:session, other}) == {scan_step(), nil}
    end

    test "a phone that arrived is compared" do
      answer =
        {:session, view("awaiting_decision", %{"ttl_ms" => 60_000, "request" => request()})}

      assert PhonePairing.reduce(scan_step(), answer) == {compare_step(), nil}
    end

    test "a resumed window is compared from Waiting" do
      answer =
        {:session, view("awaiting_decision", %{"ttl_ms" => 60_000, "request" => request()})}

      assert PhonePairing.reduce({:waiting, "s1"}, answer) == {compare_step(), nil}
    end

    test "a resumed window still waiting for a scan cannot be drawn" do
      answer = {:session, view("awaiting_scan")}

      assert {{:ended, %{action: {:start_over, "s1"}}}, nil} =
               PhonePairing.reduce({:waiting, "s1"}, answer)
    end

    for {name, field, value} <- [
          {"five digits", "sas", "48106"},
          {"letters in the digits", "sas", "48106a"},
          {"non-ASCII digits", "sas", "٤٨١٠٦٢"},
          {"an empty name", "device_name", ""},
          {"a name over 128 bytes", "device_name", String.duplicate("a", 129)},
          {"a name with a line break", "device_name", "Pixel\nApprove"},
          {"a name that reorders text", "device_name", "Pixel \u202E9"},
          {"a name with an invisible character", "device_name", "Pix\u200Bel"},
          {"a model with a byte-order mark", "model", "\uFEFFPixel 9"}
        ] do
      test "a phone with #{name} is unreadable and its window cancelled" do
        bad = request(%{unquote(field) => unquote(value)})
        answer = {:session, view("awaiting_decision", %{"request" => bad})}

        assert {{:ended, %{sentence: sentence}}, "s1"} = PhonePairing.reduce(scan_step(), answer)
        assert sentence == PhonePairing.unreadable_sentence()
      end
    end

    test "a name joined with the zero-width joiner is drawn" do
      named = request(%{"device_name" => "Rowan 👩\u200D💻"})
      answer = {:session, view("awaiting_decision", %{"request" => named})}

      assert {{:compare, %{device_name: "Rowan 👩\u200D💻"}}, nil} =
               PhonePairing.reduce(scan_step(), answer)
    end

    test "an approved window says which phone paired" do
      answer = {:session, view("approved", %{"request" => request()})}

      assert PhonePairing.reduce(compare_step(), answer) == {{:paired, "Rowan's Pixel"}, nil}
    end

    for {reason, sentence} <- [
          {"timeout", "The code expired. Pairing codes last two minutes."},
          {"denied", "You denied this phone."},
          {"cancelled", "Pairing was cancelled."}
        ] do
      test "a window ended by #{reason} says so" do
        state = %{"timeout" => "expired", "denied" => "denied", "cancelled" => "cancelled"}

        answer =
          {:session,
           view(Map.fetch!(state, unquote(reason)), %{
             "outcome" => %{"device_id" => nil, "reason" => unquote(reason)}
           })}

        assert PhonePairing.reduce(compare_step(), answer) ==
                 {{:ended, %{sentence: unquote(sentence), action: :pair_again}}, nil}
      end
    end

    test "a failed window ends with the daemon's sentence" do
      sentence =
        "The phone's secure-hardware proof was refused: only an Android phone can pair."

      answer =
        {:session, view("failed", %{"failure" => %{"code" => "refused", "sentence" => sentence}})}

      assert PhonePairing.reduce(compare_step(), answer) ==
               {{:ended, %{sentence: sentence, action: :pair_again}}, nil}
    end

    test "a state this page does not know is unreadable and cancels the window" do
      assert {{:ended, %{sentence: sentence}}, "s1"} =
               PhonePairing.reduce(scan_step(), {:session, view("rearranged")})

      assert sentence == PhonePairing.unreadable_sentence()
    end
  end

  describe "refusals" do
    test "a refusal ends with its sentence and the way to pair again" do
      assert PhonePairing.reduce(scan_step(), {:refused, "No phone is waiting."}) ==
               {{:ended, %{sentence: "No phone is waiting.", action: :pair_again}}, nil}
    end

    test "a refusal is worded by the daemon's sentence or the protocol's table" do
      messages = Protocol.error_messages()

      assert PhonePairing.refusal_sentence(
               {:invalid_params, "device_id", "No paired phone has that id."}
             ) ==
               "No paired phone has that id."

      assert PhonePairing.refusal_sentence({:unavailable, "mobile"}) == messages.unavailable

      assert PhonePairing.refusal_sentence({:unknown_pairing_session, "s1"}) ==
               messages.unknown_pairing_session

      assert PhonePairing.refusal_sentence({:busy, "mobile.pair"}) == messages.busy

      assert PhonePairing.refusal_sentence({:external_change, ["channels.mobile"]}) ==
               messages.external_change

      assert PhonePairing.refusal_sentence({:config_unreadable, "The file is not TOML."}) ==
               "The file is not TOML."

      assert PhonePairing.refusal_sentence({:unknown_section, "channels.mobile"}) ==
               messages.invalid_params
    end

    test "a code the protocol does not word fails loud" do
      assert_raise KeyError, fn -> PhonePairing.refusal_sentence({:made_up, "x"}) end
    end
  end

  describe "the open session" do
    test "is the one a step shows, and none once a window is over" do
      assert PhonePairing.open_session({:waiting, "s9"}) == "s9"
      assert PhonePairing.open_session({:waiting, nil}) == nil
      assert PhonePairing.open_session(scan_step()) == "s1"
      assert PhonePairing.open_session(compare_step()) == "s1"
      assert PhonePairing.open_session({:paired, "Pixel"}) == nil
      assert PhonePairing.open_session(:phones) == nil
      assert PhonePairing.open_session(:closed) == nil
    end
  end

  describe "the Phone row" do
    test "says Checking until the status answers, and the daemon's words when it refuses" do
      assert PhonePairing.row(nil, nil) == %{status: "Checking", opens: :pair}

      assert PhonePairing.row({:error, "Unavailable."}, nil) == %{
               status: "Unavailable.",
               opens: :pair
             }
    end

    test "follows the channel's state, in the apps' order" do
      off = status(%{"enabled" => false, "started" => false})
      assert PhonePairing.row({:ok, off}, nil).status == "Off"

      assert PhonePairing.row({:ok, status(%{"started" => false})}, nil).status ==
               "Restart to turn on"

      assert PhonePairing.row({:ok, status(%{"started" => false, "refused" => true})}, nil).status ==
               "Could not start"

      unavailable = status(%{"listener" => %{"status" => "unavailable"}})
      assert PhonePairing.row({:ok, unavailable}, nil).status == "Could not start"
      assert PhonePairing.row({:ok, status()}, nil) == %{status: "No phone paired", opens: :pair}
    end

    test "names one phone from the list and counts more" do
      one = status(%{"paired_devices" => 1})
      list = {:ok, %{"devices" => [%{"name" => "Rowan's Pixel"}]}}

      assert PhonePairing.row({:ok, one}, nil) == %{status: "Checking", opens: :phones}
      assert PhonePairing.row({:ok, one}, list) == %{status: "Rowan's Pixel", opens: :phones}

      assert PhonePairing.row({:ok, status(%{"paired_devices" => 3})}, nil) ==
               %{status: "3 phones", opens: :phones}
    end
  end

  describe "words" do
    test "the countdown rounds up so an open window never reads 0:00" do
      assert PhonePairing.countdown(120_000) == "Expires in 2:00"
      assert PhonePairing.countdown(104_001) == "Expires in 1:45"
      assert PhonePairing.countdown(1) == "Expires in 0:01"
      assert PhonePairing.countdown(0) == "Expires in 0:00"
    end

    test "the digits are drawn in threes and read one by one" do
      assert PhonePairing.grouped("481062") == "481 062"
      assert PhonePairing.spoken("481062", "Pixel") == "Pixel, 4 8 1 0 6 2"
    end

    test "a phone is seen in its largest unit" do
      now = DateTime.to_unix(~U[2026-10-20 12:00:00Z])

      assert PhonePairing.seen(nil, now) == "Not seen yet"
      assert PhonePairing.seen("2026-10-20T11:59:30Z", now) == "Seen just now"
      assert PhonePairing.seen("2026-10-20T11:59:00Z", now) == "Seen 1 minute ago"
      assert PhonePairing.seen("2026-10-20T10:00:00Z", now) == "Seen 2 hours ago"
      assert PhonePairing.seen("2026-10-20T06:00:00-05:00", now) == "Seen 1 hour ago"
      assert PhonePairing.seen("2026-10-18T12:00:00.250Z", now) == "Seen 2 days ago"
      assert PhonePairing.seen("last Tuesday", now) == nil
    end

    test "a phone's detail is its model, and when it was seen where that reads" do
      now = DateTime.to_unix(~U[2026-10-20 12:00:00Z])

      assert PhonePairing.detail("Pixel 9", "2026-10-20T10:00:00Z", now) ==
               "Pixel 9 · Seen 2 hours ago"

      assert PhonePairing.detail("Pixel 9", "last Tuesday", now) == "Pixel 9"
    end
  end

  describe "reach from anywhere" do
    test "a line for each state, the daemon's failure as written" do
      line = &PhonePairing.reach_line/1

      assert line.(nil) == nil
      assert line.(%{"state" => "off"}) == nil
      assert line.(%{"state" => "helper_missing"}) == {"Not included in this build.", :note}
      assert line.(%{"state" => "dormant"}) == {"Starts when you pair your first phone.", :note}
      assert line.(%{"state" => "starting"}) == {"Starting…", :progress}

      assert line.(%{"state" => "ready", "connected" => true}) ==
               {"Connected to Fermix's relays.", :note}

      assert line.(%{"state" => "ready", "connected" => false}) ==
               {"Not connected to Fermix's relays right now.", :note}

      assert line.(%{"state" => "failed", "failure" => "The relay refused."}) ==
               {"The relay refused.", :failure}

      assert line.(%{"state" => "failed", "failure" => nil}) == nil
      assert line.(%{"state" => "rearranged"}) == nil
    end

    test "is followed only while it can move by itself" do
      for state <- ~w(starting ready failed rearranged),
          do: assert(PhonePairing.reach_moves?(%{"state" => state}))

      for state <- ~w(off dormant helper_missing),
          do: refute(PhonePairing.reach_moves?(%{"state" => state}))

      refute PhonePairing.reach_moves?(nil)
    end
  end
end
