defmodule FermixCore.Management.PlacementTest do
  # M75 §6, B12: which engine answers a management request after a move.
  use ExUnit.Case, async: true

  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Settings

  @device ~w(
    hello lifecycle.prepare lifecycle.commit lifecycle.cancel diagnostics.build logs.query
    doctor.start doctor.get doctor.cancel setup.session.create setup.detect
    computer_use.grant.start computer_use.permissions.get imessage.permissions.get
    imessage.grant.start imessage.policy.confirm browser.install.start
    capabilities.install.start home.status settings.sections
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

  test "settings are placed by section: this machine's own, else the primary's" do
    for section <- ~w(sandbox computer_use computer_history channels.imessage) do
      assert Placement.place("settings.get", %{"section" => section}) == :device

      assert Placement.place("settings.apply", %{"section" => section, "values" => %{}}) ==
               :device
    end

    for section <- ~w(providers.openai routing memory browser channels.telegram snapshots) do
      assert Placement.place("settings.get", %{"section" => section}) == :primary
    end

    assert Placement.place("settings.get", %{}) == :primary
  end

  test "home.status and settings.sections are composed: answered here, served when forwarded" do
    for method <- ~w(home.status settings.sections) do
      assert Placement.composed?(method)
      assert Placement.place(method, %{}) == :device
      assert Placement.served_forwarded?(method, %{})
    end

    refute Placement.composed?("home.snapshots.status")
    refute Placement.served_forwarded?("settings.get", %{"section" => "sandbox"})
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

    unreachable = fn _request, _opts ->
      Placement.unreachable("fermix-vm", Placement.unreachable_sentence("fermix-vm"))
    end

    assert {:missing, "The server fermix-vm is unreachable." <> _rest} =
             Placement.primary_part(unreachable, "settings.sections")

    unworded = fn _request, _opts -> {:error, :internal_error, %{}} end

    assert {:missing, "The server did not answer this (internal_error)."} =
             Placement.primary_part(unworded, "home.status")
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

  test "only a move's start whose answer was lost is unconfirmed, a published code" do
    assert Placement.unconfirmed_on_loss?("home.move.start")

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

  test "every device-class section is one this daemon serves" do
    served = for section <- Settings.sections(macos?: true), do: section.id
    assert Placement.device_sections() -- served == []
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
