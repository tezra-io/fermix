defmodule FermixCore.Management.PlacementTest do
  # M75 §6, B12: which engine answers a management request after a move.
  use ExUnit.Case, async: true

  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Settings

  @device ~w(
    hello lifecycle.prepare lifecycle.commit lifecycle.cancel diagnostics.build logs.query
    doctor.start doctor.get doctor.cancel setup.session.create
    computer_use.grant.start computer_use.permissions.get imessage.permissions.get
    imessage.grant.start imessage.policy.confirm browser.install.start
    home.status settings.sections job.list home.act
  )

  test "the device-class methods are this machine's, whatever their parameters" do
    for method <- @device, do: assert(Placement.place(method, %{}) == :device, method)

    published = Protocol.methods()
    for method <- Placement.device_methods(), do: assert(method in published)
    assert @device -- Placement.device_methods() == []
  end

  test "every other method is the primary's" do
    primary = Protocol.methods() -- Placement.device_methods()

    assert "providers.models.list" in primary
    assert "mobile.pair.decide" in primary
    assert "secret.set" in primary
    assert "cues.status" in primary

    # The home's recovery, enrollment and move live on the server after a move.
    for method <-
          ~w(home.snapshots.status home.snapshots.run home.snapshots.passphrase home.enroll.open
             home.candidates.list home.move.readiness home.move.start) do
      assert Placement.place(method, %{}) == :primary, method
    end

    for method <- primary, do: assert(Placement.place(method, %{}) == :primary, method)
  end

  # Always On setup §3.5: the server's steps a linked desktop's `home.act`
  # sends over the link, and the create job's request for the new server's
  # code, are served only to a desktop's forward and refused on `daemon.sock`.
  test "the server's Always On steps are the rail's alone, refused elsewhere by name" do
    rail = ~w(home.move.readiness home.move.start home.enroll.open home.enroll.withdraw
              home.enroll.approve home.enroll.deny home.snapshots.run home.restart)

    assert Enum.sort(Placement.rail_only_methods()) == Enum.sort(rail)

    for method <- rail do
      assert Placement.rail_only?(method)
      assert Placement.place(method, %{}) == :primary
      assert Placement.served_forwarded?(method, %{})

      assert {:error, :unavailable,
              %{"capability" => "home", "method" => ^method, "sentence" => sentence}} =
               Placement.rail_only_refusal(method)

      assert sentence =~ "home.act"
    end

    for method <- ~w(home.act home.status home.snapshots.passphrase home.candidates.list),
        do: refute(Placement.rail_only?(method), method)

    # A linked desktop answers `home.act` itself, and the server refuses one
    # forwarded to it.
    refute Placement.served_forwarded?("home.act", %{})
  end

  # M97 §19.3 (D28): the id names the machine. `computer` and every
  # `computer.<id>` are this computer's, for every settings method and every
  # secret; every other id is the home's, the server's machine sections
  # included, and `computer_use` and `computer_history` are plain ids.
  test "settings and secrets are placed by their id: computer and computer.<id> here" do
    for section <- ~w(computer computer.sandbox computer.browser computer.computer_use
                      computer.computer_history computer.accessories),
        method <- ~w(settings.get settings.apply settings.reload) do
      assert Placement.place(method, %{"section" => section}) == :device,
             inspect({method, section})

      refute Placement.served_forwarded?(method, %{"section" => section}),
             inspect({method, section})
    end

    for id <- ~w(computer.env:LEDGER_TOKEN), method <- ~w(secret.set secret.clear) do
      assert Placement.place(method, %{"id" => id}) == :device
      refute Placement.served_forwarded?(method, %{"id" => id})
    end

    # iMessage's owner and guests are the home's (M97 §4): a linked Mac asks
    # its server, and confirms who Fermix may write to itself.
    for section <- ~w(sandbox browser harness_machine computer_use computer_history accessories
                      providers.openai routing memory channels.telegram channels.imessage
                      snapshots computer_ computer.),
        method <- ~w(settings.get settings.apply settings.reload) do
      assert Placement.place(method, %{"section" => section}) == :primary,
             inspect({method, section})
    end

    # A primary serves a forward the home's sections and its own sandbox,
    # browser and coding approval; a screen, a history and an accessory are
    # each computer's own, so a primary that is a Mac refuses another
    # computer's write of its own (device_class_method), as before the rule.
    for section <- ~w(sandbox browser harness_machine providers.openai routing memory
                      channels.imessage computer_ computer.),
        method <- ~w(settings.get settings.apply settings.reload) do
      assert Placement.served_forwarded?(method, %{"section" => section}),
             inspect({method, section})
    end

    for section <- ~w(computer_use computer_history accessories) do
      for method <- ~w(settings.get settings.apply) do
        refute Placement.served_forwarded?(method, %{"section" => section}),
               inspect({method, section})
      end

      # A reload configures nothing: it reads all of the primary's settings
      # again, whatever section an outside edit there was refused for.
      assert Placement.served_forwarded?("settings.reload", %{"section" => section}), section
    end

    for id <- ~w(env:GARDEN_TOKEN anthropic_api_key computer_api_key), method <- ~w(secret.set) do
      assert Placement.place(method, %{"id" => id}) == :primary, id
    end

    assert Placement.place("imessage.policy.confirm", %{}) == :device
    assert Placement.place("settings.get", %{}) == :primary
    assert Placement.place("settings.reload", %{}) == :primary
  end

  test "the machine sections, and the writes that are an owner decision" do
    assert Enum.sort(Placement.machine_sections()) ==
             ~w(accessories browser computer_history computer_use harness_machine sandbox)

    for section <- ["computer", "computer.sandbox" | Placement.machine_sections()] do
      assert Placement.machine_write?("settings.apply", %{"section" => section}), section
    end

    for id <- ~w(env:GARDEN_TOKEN computer.env:LEDGER_TOKEN),
        method <- ~w(secret.set secret.clear) do
      assert Placement.machine_write?(method, %{"id" => id}), id
    end

    refute Placement.machine_write?("settings.apply", %{"section" => "routing"})
    refute Placement.machine_write?("settings.get", %{"section" => "sandbox"})
    refute Placement.machine_write?("secret.set", %{"id" => "anthropic_api_key"})
  end

  # What D28 moved to the server, which a server without the rule refuses:
  # its sandbox and coding approval, its sandbox values, the coding agents'
  # check, the notetaker's and on-device speech's installers and the home's
  # detection. Its browser was the home's before the rule, and such a server
  # still serves it so.
  test "a server without the rule is asked for none of what the rule moved to it" do
    for {method, params} <- [
          {"settings.get", %{"section" => "sandbox"}},
          {"settings.apply", %{"section" => "harness_machine"}},
          {"secret.set", %{"id" => "env:GARDEN_TOKEN"}},
          {"secret.clear", %{"id" => "env:GARDEN_TOKEN"}},
          {"coding_agents.check", %{}},
          {"capabilities.install.start", %{"target" => "meetbot"}},
          {"capabilities.install.start", %{"target" => "local_stt"}},
          {"setup.detect", %{"targets" => ["claude_code", "existing_primary"]}}
        ] do
      assert Placement.server_machine_request?(method, params), inspect({method, params})
    end

    for {method, params} <- [
          {"settings.get", %{"section" => "routing"}},
          {"settings.get", %{"section" => "browser"}},
          {"settings.apply", %{"section" => "browser"}},
          {"settings.reload", %{"section" => "sandbox"}},
          {"settings.reload", %{}},
          {"secret.set", %{"id" => "anthropic_api_key"}},
          {"capabilities.install.start", %{"target" => "computer_use_sidecar"}}
        ] do
      refute Placement.server_machine_request?(method, params), inspect({method, params})
    end

    assert {:error, :unavailable, %{"capability" => "settings", "sentence" => sentence}} =
             Placement.older_server("garden server")

    assert sentence ==
             "garden server runs an older Fermix, which takes its own sandbox and coding " <>
               "settings only on the server. It updates on its own."

    assert {:error, :unavailable, %{"sentence" => "Update Fermix on this computer" <> _rest}} =
             Placement.older_computer()
  end

  test "a request for a server without the rule is sent as before the rule, or answered here" do
    sent = fn method, params ->
      Placement.to_older_server(%{request_id: "r-1", method: method, params: params}, "garden")
    end

    # The browser is the home's on such a server, and its reload takes no
    # section: an outside edit is cleared by reloading the whole server.
    assert {:send, %{params: %{"section" => "browser"}}} =
             sent.("settings.get", %{"section" => "browser"})

    assert {:send, %{method: "settings.reload", params: %{}}} =
             sent.("settings.reload", %{"section" => "channels.telegram"})

    assert {:send, %{params: %{}}} = sent.("settings.reload", %{})

    assert {:answer, refusal} = sent.("settings.apply", %{"section" => "sandbox"})
    assert refusal == Placement.older_server("garden")

    for {method, params} <- [
          {"coding_agents.check", %{}},
          {"capabilities.install.start", %{"target" => "meetbot"}},
          {"setup.detect", %{"targets" => ["harness_vendors"]}}
        ] do
      assert {:answer, {:error, :unavailable, details}} = sent.(method, params)

      assert details == %{
               "capability" => "settings",
               "sentence" =>
                 "garden runs an older Fermix, which does this only on the server itself. " <>
                   "It updates on its own."
             }
    end

    assert {:answer, {:error, :unavailable, %{"sentence" => "Your server runs" <> _rest}}} =
             Placement.to_older_server(
               %{request_id: "r-2", method: "coding_agents.check", params: %{}},
               nil
             )
  end

  # A linked computer lists the server's sections as the server serves them
  # to it: never a computer id, never a screen, history or accessory of the
  # server's, and its sandbox and coding approval only where it says the rule.
  test "the server's sections a linked computer lists" do
    for rule? <- [true, false] do
      for id <- ~w(routing providers.openai browser) do
        assert Placement.listed_from_server?(id, rule?), inspect({id, rule?})
      end

      for id <- ~w(computer computer.sandbox computer_use computer_history accessories) do
        refute Placement.listed_from_server?(id, rule?), inspect({id, rule?})
      end
    end

    for id <- ~w(sandbox harness_machine) do
      assert Placement.listed_from_server?(id, true)
      refute Placement.listed_from_server?(id, false)
    end
  end

  # After a move the notetaker, the local speech-to-text and the coding
  # agents run on the server; computer use's helper and Messages' here.
  test "installers and detection are placed by what they are for" do
    for target <- ~w(meetbot local_stt),
        do:
          assert(Placement.place("capabilities.install.start", %{"target" => target}) == :primary)

    for target <- ~w(computer_use_sidecar imessage_helper),
        do:
          assert(Placement.place("capabilities.install.start", %{"target" => target}) == :device)

    assert Placement.place("coding_agents.check", %{}) == :primary
    assert Placement.place("setup.detect", %{"targets" => ["harness_vendors"]}) == :primary
    assert Placement.place("setup.detect", %{"targets" => ["meetbot", "ollama"]}) == :primary

    # The home's chosen provider is read from the home's settings, so the
    # Providers pane's whole detection is the server's, as auth.import is.
    assert Placement.place("setup.detect", %{"targets" => ["existing_primary"]}) == :primary

    assert Placement.place("setup.detect", %{"targets" => ["claude_code", "existing_primary"]}) ==
             :primary

    assert Placement.place("setup.detect", %{"targets" => ["existing_primary", "codex_cli"]}) ==
             :primary

    # One this engine does not know is refused here, never sent.
    assert Placement.place("setup.detect", %{"targets" => ["existing_primary", "kettle"]}) ==
             :device

    assert Placement.place("setup.detect", %{"targets" => []}) == :device

    # A job is answered by the engine that started it.
    for method <- ~w(job.get job.cancel) do
      assert Placement.place(method, %{"job_id" => "computer.job:Q2x9"}) == :device
      refute Placement.served_forwarded?(method, %{"job_id" => "computer.job:Q2x9"})
      assert Placement.place(method, %{"job_id" => "job:Q2x9"}) == :primary
    end

    for method <- ~w(setup.state.get overview.get), do: assert(Placement.decorated?(method))
    refute Placement.decorated?("settings.get")
  end

  # M97 D28: job.list too, so a linked computer lists the jobs it started
  # itself (`computer.job:<id>`) beside the server's.
  test "home.status, settings.sections and job.list are composed: answered here, served when forwarded" do
    for method <- ~w(home.status settings.sections job.list) do
      assert Placement.composed?(method)
      assert Placement.place(method, %{}) == :device
      assert Placement.served_forwarded?(method, %{})
    end

    refute Placement.composed?("home.snapshots.status")
    refute Placement.served_forwarded?("settings.get", %{"section" => "computer.sandbox"})
    assert Placement.served_forwarded?("settings.get", %{"section" => "sandbox"})
    assert Placement.served_forwarded?("settings.get", %{"section" => "routing"})
    assert Placement.composed_deadline_ms() < 10_000
  end

  test "the primary's part of a composed answer is asked within its deadline, or said missing" do
    test = self()

    answered = fn request, opts ->
      send(test, {:asked, request, opts})
      {:ok, %{"role" => "primary"}}
    end

    assert {:ok, %{"role" => "primary"}} = Placement.primary_part(answered, "home.status")
    assert_received {:asked, %{method: "home.status", params: %{}}, [deadline_ms: 5_000]}

    assert {:ok, %{"role" => "primary"}} = Placement.primary_part(answered, "job.list")
    assert_received {:asked, %{method: "job.list", params: %{}}, [deadline_ms: 5_000]}

    unreachable = fn _request, _opts ->
      Placement.unreachable("fermix-vm", Placement.unreachable_sentence("fermix-vm"))
    end

    assert {:missing, "The server fermix-vm is unreachable." <> _rest} =
             Placement.primary_part(unreachable, "settings.sections")

    unworded = fn _request, _opts -> {:error, :internal_error, %{}} end

    assert {:missing, "The server did not answer this (internal_error)."} =
             Placement.primary_part(unworded, "home.status")

    # Review M4: a server on an older protocol than this computer's, until
    # its update takes a newer one, is said apart from one that is missing.
    # M97 §3.4: the server leads, updating once the apps carry the release.
    older = fn _request, _opts -> {:error, :daemon_too_old, %{"maximum_version" => 2}} end

    assert {:behind,
            "The server runs an older Fermix than this computer. It updates on its own " <>
              "once the app for each computer that keeps your backups carries the newer " <>
              "one."} = Placement.primary_part(older, "home.status")
  end

  # A section named here that no build serves would place nothing.
  test "a desktop waits 60 s for the move's two walks of the home, 8 s for every other call" do
    long = ~w(home.move.readiness home.move.start)

    for method <- long, do: assert(Placement.forward_deadline_ms(method) == 60_000, method)
    assert Map.keys(Placement.long_forward_deadlines()) == long

    for method <- Protocol.methods() -- long,
        do: assert(Placement.forward_deadline_ms(method) == 8_000, method)
  end

  # The apps read the timeout they owe these calls from the export, so the
  # export says every deadline past 8 s, and a client timeout 5 s past it.
  test "PROTOCOL.md publishes every longer deadline and the client timeout it needs" do
    doc = File.read!(Application.app_dir(:fermix_core, "priv/management/PROTOCOL.md"))

    for {method, ms} <- Placement.long_forward_deadlines() do
      seconds = div(ms, 1_000)
      assert doc =~ "| `#{method}` | #{seconds} s | at least #{seconds + 5} s |", method
    end

    assert doc =~ "| every other forwarded method | 8 s | the usual 10 s |"
  end

  test "only a move's start or a restart whose answer was lost is unconfirmed, a published code" do
    assert Placement.unconfirmed_on_loss?("home.move.start")

    # M97 D28c: the server restarts right after it answers Restart <server>,
    # so a lost answer is no failure either.
    assert Placement.unconfirmed_on_loss?("home.restart")

    assert Placement.unconfirmed("north-box", "home.restart") ==
             {:error, :unconfirmed,
              %{
                "method" => "home.restart",
                "primary" => "north-box",
                "sentence" =>
                  "The server north-box was asked to restart and did not confirm it in time. " <>
                    "Always On shows how it stands once the server is back."
              }}

    assert {:error, :unconfirmed, %{"sentence" => "The server was asked" <> _rest}} =
             Placement.unconfirmed(nil, "home.restart")

    for method <- ~w(home.move.readiness home.snapshots.run settings.apply cues.status),
        do: refute(Placement.unconfirmed_on_loss?(method), method)

    assert {:error, :unconfirmed, details} = Placement.unconfirmed("north-box", "home.move.start")

    assert details == %{
             "method" => "home.move.start",
             "primary" => "north-box",
             "sentence" =>
               "The server north-box did not confirm in time whether the move started. Its " <>
                 "state shows once the server answers again, and starting it again never " <>
                 "starts a second move."
           }

    assert {:error, :unconfirmed, %{"sentence" => "The server did not" <> _rest} = unnamed} =
             Placement.unconfirmed(nil, "home.move.start")

    refute Map.has_key?(unnamed, "primary")
    assert {:ok, _response} = Protocol.respond("req-1", {:error, :unconfirmed, details})
  end

  # This computer's section (M97 §7.2) is served on a linked computer only,
  # and whether coding agents may run here (M98 D5) only where the coding
  # rail runs, never on a computer whose home is on its server.
  test "every machine section is one this daemon serves, on a computer or on its own" do
    served =
      for computer? <- [true, false],
          section <- Settings.sections(macos?: true, computer?: computer?, server_primary?: false),
          do: section.id

    assert ["computer" | Placement.machine_sections()] -- served == []

    refute "harness_machine" in for(
             section <- Settings.sections(macos?: true, computer?: true),
             do: section.id
           )
  end

  test "the refusals are published codes with their sentences" do
    assert {:error, :primary_unreachable, details} =
             Placement.unreachable("fermix-vm", Placement.unreachable_sentence("fermix-vm"))

    assert details == %{
             "primary" => "fermix-vm",
             "sentence" =>
               "The server fermix-vm is unreachable. Fermix keeps your message until it is back."
           }

    assert {:error, :primary_unreachable, %{"sentence" => sentence}} =
             Placement.unreachable(nil, Placement.unreachable_sentence(nil))

    assert sentence ==
             "Fermix cannot reach its server. Fermix keeps your message until it is back."

    assert {:error, :device_class_method, %{"method" => "hello", "sentence" => _sentence}} =
             refusal = Placement.device_class_refusal("hello")

    for {:error, code, details} <- [refusal, Placement.unreachable(nil, sentence)] do
      assert {:ok, %{"error" => %{"code" => _code}}} =
               Protocol.respond("req-1", {:error, code, details})
    end
  end
end
