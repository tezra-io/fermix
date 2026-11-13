defmodule FermixCore.Computers.OffersTest do
  # M97 §3.2: what a computer offers its server, worked out from its switches
  # and its facts, every machine named by the test and none read.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Facts
  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Switches

  @mac [
    os: :macos,
    arch: "arm64",
    landlock: :not_asked,
    helpers: %{computer_use: true},
    sandbox_mode: :standard,
    roots: ["/Users/avery/.fermix/workspace", "/Users/avery/Projects"],
    home: "/Users/avery",
    recording: true
  ]
  @linux [
    os: :linux,
    arch: "x86_64",
    landlock: :ok,
    helpers: %{computer_use: true},
    sandbox_mode: :strict,
    roots: ["/home/rowan/.fermix/workspace"],
    home: "/home/rowan",
    recording: false
  ]
  @all_on Switches.only(Switches.switches())

  defp states(facts, switches \\ @all_on) do
    Offers.modules()
    |> Offers.compute(switches, Facts.read(facts))
    |> Map.new(&{&1.id, {&1.state, &1.sentence || &1.detail}})
  end

  describe "compute" do
    test "an Apple silicon Mac with everything on offers all of it, the shell and the screen with its mode" do
      assert states(@mac) == %{
               "files" => {:on, nil},
               "shell" => {:on, "standard"},
               "browser" => {:on, nil},
               "computer_use" => {:on, "standard"},
               "imessage" => {:on, nil},
               "history" => {:on, nil}
             }
    end

    test "a Linux computer has no Messages and no history yet" do
      states = states(@linux)

      assert states["shell"] == {:on, "strict"}
      assert {:unavailable, "Messages runs only on a Mac."} = states["imessage"]

      assert {:unavailable, "Fermix records computer history only on a Mac for now."} =
               states["history"]
    end

    test "a Linux kernel that does not hold commands leaves the shell unavailable" do
      facts = Keyword.put(@linux, :landlock, {:error, "Landlock is absent"})
      assert {:unavailable, sentence} = states(facts)["shell"]
      assert sentence =~ "kernel"
    end

    # M97 §6.4: the server's tool follows the helper of the machine a call runs
    # on, so the screen's offer carries what this computer's helper offers.
    test "the screen carries its helper's actions and input methods, and its access level" do
      screen = %{actions: ~w(screenshot left_click elements press), input_methods: ["ax"]}
      facts = Facts.read(Keyword.merge(@linux, screen: screen))

      [offer] = Offers.compute([FermixCore.Computers.Offers.ComputerUse], @all_on, facts)

      assert %{id: "computer_use", state: :on, detail: "strict", helper: ^screen} = offer
      assert {:ok, payload, _rev} = Offers.encode([offer])
      assert {:ok, [^offer]} = Offers.decode(payload)
    end

    test "a screen whose helper said nothing yet carries no helper" do
      facts = Facts.read(Keyword.merge(@mac, screen: %{actions: [], input_methods: []}))
      [offer] = Offers.compute([FermixCore.Computers.Offers.ComputerUse], @all_on, facts)

      refute Map.has_key?(offer, :helper)
      assert {:ok, payload, _rev} = Offers.encode([offer])
      refute payload =~ "helper"
    end

    test "the screen needs the right processor, the helper and its permission" do
      assert {:unavailable, _arch} = states(Keyword.put(@mac, :arch, "x86_64"))["computer_use"]
      assert {:unavailable, _arch} = states(Keyword.put(@linux, :arch, "arm64"))["computer_use"]

      assert {:unavailable, helper} =
               states(Keyword.put(@mac, :helpers, %{computer_use: false}))["computer_use"]

      assert helper =~ "Fermix Computer Use helper"

      assert {:unavailable, permission} =
               states(Keyword.put(@mac, :permissions, %{screen: false}))["computer_use"]

      assert permission =~ "has not allowed"
    end

    test "a switch off, the master off and a review waiting each say why" do
      off = states(@mac, Switches.only([:browser]))
      assert off["browser"] == {:on, nil}
      assert {:off, "Switched off on this Mac." <> _rest} = off["files"]
      assert {:off, "Switched off on this Mac." <> _rest} = off["shell"]

      master = states(@mac, Keyword.put(@all_on, :enabled, false))
      assert {:off, "Everything Fermix on your server may use" <> _rest} = master["files"]

      waiting = states(@linux, Keyword.put(@all_on, :reviewed, false))
      assert {:off, "Waiting for you to review" <> rest} = waiting["files"]
      assert rest =~ "this computer."
      # What cannot work here says so whatever the switches.
      assert {:unavailable, _sentence} = waiting["imessage"]
    end

    test "a computer with no section offers nothing a switch decides" do
      states = states(@mac, [])
      for {id, {state, _said}} <- states, id != "history", do: assert(state == :off, id)
      # Its history follows its recorder alone (M97 D27).
      assert states["history"] == {:on, nil}
    end

    # M97 D27: one switch decides files and commands together.
    test "files and commands are on and off together" do
      on = states(@mac, Switches.only([:files_and_shell]))
      assert on["files"] == {:on, nil}
      assert on["shell"] == {:on, "standard"}
      assert {:off, _sentence} = on["browser"]
    end

    # M97 §6.4, finding F5: the server is told which folders files and
    # commands reach on this computer, so a request for another is answered
    # by name rather than tried and refused.
    test "files carries the folders files and commands reach here, while it is on" do
      [files] = Offers.compute([FermixCore.Computers.Offers.Files], @all_on, Facts.read(@mac))
      # With the home `~` stands for there, so the server can say the
      # folders without the account's name.
      assert %{id: "files", state: :on, roots: roots, home: "/Users/avery"} = files
      assert roots == @mac[:roots]
      assert {:ok, payload, _rev} = Offers.encode([files])
      assert {:ok, [^files]} = Offers.decode(payload)

      off = Offers.compute([FermixCore.Computers.Offers.Files], [], Facts.read(@mac))
      refute Map.has_key?(hd(off), :roots)
    end

    # The payload's bounds: a folder the wire cannot carry is left out, and
    # never stops the rest of what this computer offers.
    test "a folder the wire cannot carry is left out, and the folders are bounded" do
      odd = ["relative/folder", "/Users/avery/bad\nname", "/" <> String.duplicate("a", 1024)]
      many = for n <- 1..40, do: "/Volumes/Shelf#{n}"
      facts = Facts.read(Keyword.put(@mac, :roots, ["/Users/avery/Projects" | odd] ++ many))

      [files] = Offers.compute([FermixCore.Computers.Offers.Files], @all_on, facts)
      assert hd(files.roots) == "/Users/avery/Projects"
      assert length(files.roots) == 32
      assert Enum.all?(files.roots, &(&1 == "/Users/avery/Projects" or &1 =~ "/Volumes/Shelf"))
      assert {:ok, _payload, _rev} = Offers.encode([files])

      none = Facts.read(Keyword.put(@mac, :roots, odd))
      [files] = Offers.compute([FermixCore.Computers.Offers.Files], @all_on, none)
      refute Map.has_key?(files, :roots)
    end

    # M97 D27: history has no switch here. It is offered while this
    # computer's recorder is on (its own setting, the history section's), the
    # master on and the switches reviewed, and in no other case.
    test "history follows its recorder under the master, and nothing else" do
      for enabled <- [true, false], reviewed <- [true, false], recording <- [true, false] do
        switches = Switches.only([], enabled: enabled, reviewed: reviewed)
        {state, _said} = states(Keyword.put(@mac, :recording, recording), switches)["history"]
        offered = enabled and reviewed and recording
        assert state == if(offered, do: :on, else: :off), inspect({enabled, reviewed, recording})
      end

      assert {:off, "Switched off on this Mac." <> _rest} =
               states(Keyword.put(@mac, :recording, false))["history"]
    end
  end

  describe "the wire" do
    test "encode and decode round-trip, and the rev is the payload's own" do
      offers = Offers.compute(Offers.modules(), @all_on, Facts.read(@linux))

      assert {:ok, payload, rev} = Offers.encode(offers)
      assert Offers.rev?(rev)
      assert rev == Offers.rev(payload)
      assert {:ok, ^offers} = Offers.decode(payload)
      refute payload =~ "null"
    end

    test "each violation is named" do
      cases = [
        {"[]", "not a JSON object"},
        {"nope", "not JSON"},
        {~s({"v":2,"offers":[]}), "v is not 1"},
        {~s({"v":1,"offers":{}}), "offers is not a list"},
        {many(33), "more than 32 offers"},
        {one(%{"id" => "Files", "state" => "on"}), "its id is not an id"},
        {one(%{"id" => "files", "state" => "maybe"}), "not on, off or unavailable"},
        {one(%{"id" => "files", "state" => "off"}), "it has no sentence"},
        {one(%{"id" => "files", "state" => "off", "sentence" => "bad\nline"}), "its sentence"},
        {one(%{"id" => "files", "state" => "off", "sentence" => String.duplicate("a", 301)}),
         "its sentence"},
        {one(%{"id" => "files", "state" => "on", "detail" => String.duplicate("a", 65)}),
         "its detail"},
        {one(%{"state" => "on"}), "no id or no state"},
        {one(%{"id" => "computer_use", "state" => "on", "helper" => %{"actions" => []}}),
         "names no actions or no input methods"},
        {one(%{
           "id" => "computer_use",
           "state" => "on",
           "helper" => %{"actions" => [], "input_methods" => []}
         }), "its helper is not"},
        {one(%{
           "id" => "computer_use",
           "state" => "on",
           "helper" => %{"actions" => ["Click"], "input_methods" => []}
         }), "its helper is not"},
        {one(%{
           "id" => "computer_use",
           "state" => "on",
           "helper" => %{"actions" => many_names(65), "input_methods" => []}
         }), "its helper is not"},
        {one(%{"id" => "files", "state" => "on", "roots" => []}), "its roots"},
        {one(%{"id" => "files", "state" => "on", "roots" => ["workspace"]}), "its roots"},
        {one(%{"id" => "files", "state" => "on", "roots" => ["/a\nb"]}), "its roots"},
        {one(%{"id" => "files", "state" => "on", "roots" => many_roots(33)}), "its roots"},
        {one(%{"id" => "files", "state" => "on", "roots" => "/Users"}), "its roots"},
        {one(%{"id" => "files", "state" => "on", "home" => "Users/avery"}), "its home"},
        {one(%{"id" => "files", "state" => "on", "home" => ["/Users/avery"]}), "its home"},
        {~s({"v":1,"offers":[1]}), "not an object"},
        {~s({"v":1,"offers":[{"id":"files","state":"on"},{"id":"files","state":"on"}]}),
         "files is named more than once"}
      ]

      for {payload, said} <- cases do
        assert {:error, {:invalid_offers, sentence}} = Offers.decode(payload)
        assert sentence =~ said, "#{payload}: #{sentence}"
      end
    end

    test "an id this engine has no module for is kept as it came" do
      payload = one(%{"id" => "camera", "state" => "unavailable", "sentence" => "Not yet."})

      assert {:ok, [%{id: "camera", state: :unavailable, sentence: "Not yet."}]} =
               Offers.decode(payload)
    end

    test "32 offers is the bound, and an empty list is nothing offered" do
      assert {:ok, offers} = Offers.decode(many(32))
      assert length(offers) == 32
      assert {:ok, []} = Offers.decode(~s({"v":1,"offers":[]}))
    end
  end

  defp one(offer), do: Jason.encode!(%{"v" => 1, "offers" => [offer]})

  defp many_roots(n), do: for(i <- 1..n, do: "/Volumes/Shelf#{i}")

  defp many(count) do
    offers = for index <- 1..count, do: %{"id" => "offer_#{index}", "state" => "on"}
    Jason.encode!(%{"v" => 1, "offers" => offers})
  end

  defp many_names(count), do: for(index <- 1..count, do: "action_#{index}")
end
