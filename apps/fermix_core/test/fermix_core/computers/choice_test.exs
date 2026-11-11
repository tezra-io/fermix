defmodule FermixCore.Computers.ChoiceTest do
  # M97 §6.5: which machine a tool call runs on, never silently. Each rule, and
  # each refusal, which runs nothing and is the call's one exec event.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Clock
  alias FermixCore.Computers.Capabilities.Files
  alias FermixCore.Computers.Choice
  alias FermixCore.Computers.Computer
  alias FermixCore.Management.Copy
  alias FermixCore.Tools.FileRead
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry
  alias FermixCore.Tools.WebFetch
  alias FermixTestSupport.TelemetryCapture

  # A capability this server's host does not have (a screen, say): a call that
  # names no computer goes to the one that offers it, or is refused.
  defmodule Elsewhere do
    @moduledoc false
    def id, do: :computer_use
    def offer, do: :computer_use
    def here?(_context), do: false
  end

  def run(args, context, test_pid) do
    send(test_pid, {:executed, args, context})
    ToolTelemetry.exec("read_elsewhere", context, true, 0)
    {:ok, %{success: true, output: "ran", error: nil}}
  end

  setup do
    sid = "choice-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: sid)
    %{sid: sid}
  end

  defp offer(id, state, sentence \\ nil),
    do: %{id: id, state: state, sentence: sentence, detail: nil}

  defp studio,
    do: %Computer{
      device_id: "a1",
      name: "studio Mac",
      platform: :macos,
      connected: true,
      offers: [offer("files", :on), offer("computer_use", :on)]
    }

  defp loft,
    do: %Computer{
      device_id: "b2",
      name: "loft Linux",
      platform: :linux,
      connected: true,
      offers: [offer("files", :off, "Switched off on this computer."), offer("computer_use", :on)]
    }

  defp files, do: Builtin.from_tool_module(FileRead)

  defp elsewhere do
    Capability.new(%{
      name: "read_elsewhere",
      description: "A tool whose capability this server lacks.",
      parameters: %{type: "object", properties: %{}},
      kind: :builtin,
      executor: {__MODULE__, :run, [self()]},
      metadata: %{computer: Elsewhere}
    })
  end

  defp context(sid, computers),
    do: %{session_id: sid, agent_name: "main", source_trust: :operator, computers: computers}

  describe "a call that names no computer" do
    test "runs here when this server has the capability", %{sid: sid} do
      assert {:ok, %{"path" => "notes.txt"}, %{computer: :here}} =
               Choice.resolve(files(), %{"path" => "notes.txt"}, context(sid, [studio()]))
    end

    test "runs on the one computer that offers it when this server does not", %{sid: sid} do
      only = [%{loft() | offers: [offer("computer_use", :off)]}, studio()]

      assert {:ok, %{}, %{computer: %Computer{name: "studio Mac"}}} =
               Choice.resolve(elsewhere(), %{}, context(sid, only))
    end

    test "is refused, asking for a name, when several computers offer it", %{sid: sid} do
      assert {:refused, :ambiguous, sentence} =
               Choice.resolve(elsewhere(), %{}, context(sid, [studio(), loft()]))

      assert sentence ==
               "studio Mac and loft Linux both offer your screen. Name the computer to use."
    end

    test "is refused when no machine offers it", %{sid: sid} do
      assert {:refused, :not_offered, "None of your computers offers your screen now."} =
               Choice.resolve(elsewhere(), %{}, context(sid, []))
    end
  end

  describe "a call that names a computer" do
    test "runs there, the argument taken off, compared without case", %{sid: sid} do
      args = %{"path" => "notes.txt", "computer" => "STUDIO mac"}

      assert {:ok, %{"path" => "notes.txt"} = run_args, %{computer: %Computer{device_id: "a1"}}} =
               Choice.resolve(files(), args, context(sid, [studio(), loft()]))

      refute Map.has_key?(run_args, "computer")
    end

    test "that is away is refused at once, with when it was last seen", %{sid: sid} do
      seen = ~U[2026-11-09 14:02:00Z]
      away = %{studio() | connected: false, last_seen: seen}

      assert {:refused, :away, sentence} =
               Choice.resolve(files(), %{"computer" => "studio Mac"}, context(sid, [away]))

      assert sentence ==
               "studio Mac is asleep or offline (last seen #{Clock.stated_instant(seen)}), so " <>
                 "Fermix cannot reach it now. Nothing waits for it to wake."
    end

    test "that never connected is refused as away", %{sid: sid} do
      never = %{studio() | connected: false}

      assert {:refused, :away, "studio Mac has not connected yet, so Fermix cannot reach it now."} =
               Choice.resolve(files(), %{"computer" => "studio Mac"}, context(sid, [never]))
    end

    # The argument is never advertised to a turn that cannot see computers
    # (`Computers.visible?/1`), and a model can still send it: that turn has no
    # computers, so the call reaches none, and the link is never asked.
    test "from a turn that cannot see computers reaches none of them", %{sid: sid} do
      no_link = FermixCore.Computers.ChoiceTest.NoLinkLoaded
      refute Code.ensure_loaded?(no_link)
      args = %{"path" => "notes.txt", "computer" => "studio Mac"}

      for context <- [
            %{context(sid, [studio()]) | source_trust: :guest},
            Map.delete(context(sid, [studio()]), :source_trust),
            Map.put(context(sid, [studio()]), :always_on, false),
            %{
              session_id: sid,
              source_trust: :operator,
              computers_opts: [link: no_link, role: :device]
            }
          ] do
        assert {:refused, :no_such_computer, "Your Fermix has no computer called studio Mac."} =
                 Choice.resolve(files(), args, context)
      end

      # Naming none, it runs here as it always did.
      guest = %{context(sid, [studio()]) | source_trust: :guest}
      assert {:ok, _args, %{computer: :here}} = Choice.resolve(files(), %{"path" => "x"}, guest)
    end

    test "that the home does not have is refused by name", %{sid: sid} do
      assert {:refused, :no_such_computer, "Your Fermix has no computer called attic Mac."} =
               Choice.resolve(files(), %{"computer" => "attic Mac"}, context(sid, [studio()]))

      assert {:refused, :no_such_computer, _sentence} =
               Choice.resolve(files(), %{"computer" => 7}, context(sid, [studio()]))
    end

    test "that does not offer the capability is refused by name", %{sid: sid} do
      assert {:refused, :not_offered, sentence} =
               Choice.resolve(files(), %{"computer" => "loft Linux"}, context(sid, [loft()]))

      assert sentence ==
               "loft Linux has files switched off. Only someone at loft Linux can switch it on."
    end

    test "past the version window is refused by name", %{sid: sid} do
      old = %{studio() | standing: :settings_only, offers: []}

      assert {:refused, :settings_only, sentence} =
               Choice.resolve(files(), %{"computer" => "studio Mac"}, context(sid, [old]))

      assert sentence =~ "studio Mac runs a Fermix too old for this server"
    end
  end

  test "a tool no computer can run keeps its arguments, a computer key too", %{sid: sid} do
    fetch = Builtin.from_tool_module(WebFetch)
    args = %{"url" => "https://example.test", "computer" => "studio Mac"}

    assert {:ok, ^args, context} = Choice.resolve(fetch, args, context(sid, [studio()]))
    refute Map.has_key?(context, :computer)
  end

  describe "a refusal at the invoke boundary" do
    test "runs nothing and is the call's one exec event, marked as before anything ran",
         %{sid: sid} do
      context = context(sid, [studio(), loft()])

      assert {:ok, %{success: false, error: error}} =
               Capability.execute(elsewhere(), %{}, context)

      assert error =~ "Name the computer to use."
      refute_received {:executed, _args, _context}

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measure, metadata}
      assert metadata.tool == "read_elsewhere"
      assert metadata.success == false
      assert metadata.computer_refusal == "ambiguous"

      assert metadata.policy_enforcement == %{
               source: "computers",
               decision: "deny",
               phase: "pre_execution"
             }

      refute_received {:telemetry, [:fermix, :tool, :exec], _measure, _more}
    end

    test "a chosen call reaches the executor without the argument", %{sid: sid} do
      context = context(sid, [studio()])

      assert {:ok, %{success: true}} =
               Capability.execute(elsewhere(), %{"computer" => "studio Mac"}, context)

      assert_received {:executed, args, %{computer: %Computer{name: "studio Mac"}}}
      assert args == %{}
    end
  end

  # The time a computer was last seen is the clock's, its day and month
  # capitalized as names are.
  test "every sentence obeys the copy rules and names what it is about" do
    names = ["studio Mac", "loft Linux", "attic Mac", "Sunday", "November"]

    for module <- [Files, Elsewhere], sentence <- Choice.sentences(module) do
      assert Copy.violations(sentence, :prose, names) == [], sentence
    end

    assert length(Enum.uniq(Choice.sentences(Files))) == length(Choice.sentences(Files))
  end
end
