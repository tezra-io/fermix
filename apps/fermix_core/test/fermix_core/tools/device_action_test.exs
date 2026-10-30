defmodule FermixCore.Tools.DeviceActionTest do
  @moduledoc """
  M75 §11, B11: `device_action`, one bounded action on the owner's own desktop.
  When it is offered, which desktop it reaches, the named refusals (an
  unavailable desktop runs nothing and queues nothing), what the model reads
  for each outcome, a file as attachment content parts, and its one exec
  event.

  The desktops are the configured double's (`FermixTestSupport.DeviceActionsDouble`),
  scripted in this test's own process, so nothing global is read or changed.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Attachments
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Tools.DeviceAction
  alias FermixTestSupport.DeviceActionsDouble
  alias FermixTestSupport.TelemetryCapture

  @mac %{device_id: "desk-mac-1", name: "Studio Mac", executor: true, connected: true}
  @linux %{device_id: "desk-lin-2", name: "Attic Linux", executor: true, connected: true}
  @pdf "%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n"

  setup do
    sid = "device-action-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: sid)

    %{sid: sid}
  end

  defp owner(ctx, extra \\ %{}) do
    Map.merge(
      %{
        source_trust: :operator,
        computer_use_origin: :interactive,
        session_id: ctx.sid,
        agent_name: "main",
        conversation_key: {"companion", ctx.sid, :root},
        engine_role: %{role: :primary, primary: nil}
      },
      extra
    )
  end

  defp desktops(rows, invoke \\ fn _id, _action, _args, _opts -> flunk("nothing is sent") end),
    do: DeviceActionsDouble.install(rows, invoke)

  defp answer(outcome), do: fn _id, _action, _args, _opts -> outcome end

  describe "where it is offered" do
    test "it is seeded with the built-ins, owner-only, and decided by the access gate" do
      assert DeviceAction in BuiltinSeeder.builtin_tool_modules()
      capability = Builtin.from_tool_module(DeviceAction)
      assert capability.policy_class == :exec
      assert capability.owner_only? == true
      assert capability.metadata.owner_approval? == true
    end

    test "only while a desktop row lets actions run", ctx do
      refute DeviceAction.advertise?(owner(ctx))

      desktops([%{@mac | executor: false}])
      refute DeviceAction.advertise?(owner(ctx))

      desktops([%{@mac | connected: false}])
      assert DeviceAction.advertise?(owner(ctx))
    end

    test "only on the primary", ctx do
      desktops([@mac])
      assert DeviceAction.advertise?(owner(ctx))
      refute DeviceAction.advertise?(owner(ctx, %{engine_role: %{role: :device, primary: "vm"}}))
      refute DeviceAction.advertise?(owner(ctx, %{engine_role: nil}))
    end

    test "on the owner's turn and a job they scheduled, never a guest, worker or cue run", ctx do
      desktops([@mac])
      scheduled = owner(ctx) |> Map.delete(:computer_use_origin) |> Map.put(:job_id, "job_1")

      assert DeviceAction.advertise?(scheduled)
      refute DeviceAction.advertise?(owner(ctx, %{source_trust: :guest}))
      refute DeviceAction.advertise?(owner(ctx, %{subagent_depth: 1}))
      refute DeviceAction.advertise?(owner(ctx, %{computer_use_origin: :unattended}))
      refute DeviceAction.advertise?(Map.put(scheduled, :trigger, "cue"))
    end

    test "the device enum names the desktop rows", ctx do
      desktops([@mac, @linux])
      schema = DeviceAction.dynamic_parameters(owner(ctx))
      assert schema.properties.device.enum == ["Studio Mac", "Attic Linux"]
      assert schema.properties.action.enum == DeviceAction.actions()
    end
  end

  describe "which desktop" do
    test "an unavailable desktop is refused by name, and nothing is sent or queued", ctx do
      desktops([%{@mac | connected: false}])

      assert {:ok, %{success: false, error: error}} =
               DeviceAction.execute(%{"action" => "list_directory", "path" => "~"}, owner(ctx))

      assert error == "Your Studio Mac is unavailable; nothing was run."
      refute_received {:device_action_invoked, _id, _action, _args, _opts}

      assert_received {:telemetry, [:fermix, :tool, :exec], _measurements,
                       %{outcome: "unavailable", success: false}}
    end

    test "a desktop whose actions the primary turned off is refused", ctx do
      desktops([%{@mac | executor: false}])

      assert {:ok, %{success: false, error: error}} =
               DeviceAction.execute(%{"action" => "list_directory", "path" => "~"}, owner(ctx))

      assert error =~ "Actions on your Studio Mac are turned off"
      refute_received {:device_action_invoked, _id, _action, _args, _opts}
    end

    test "with two desktops one must be named, and the named one is used", ctx do
      desktops([@mac, @linux], answer({:ok, ok_result(%{})}))
      args = %{"action" => "notify", "title" => "Tea", "body" => "The kettle is on."}

      assert {:ok, %{success: false, error: error}} = DeviceAction.execute(args, owner(ctx))
      assert error =~ "More than one desktop is paired (Studio Mac, Attic Linux)"
      refute_received {:device_action_invoked, _id, _action, _args, _opts}

      assert {:ok, %{success: true}} =
               DeviceAction.execute(Map.put(args, "device", "attic linux"), owner(ctx))

      assert_received {:device_action_invoked, "desk-lin-2", "notify", _args, _opts}
    end

    test "an unknown name lists the desktops", ctx do
      desktops([@mac])

      assert {:ok, %{success: false, error: error}} =
               DeviceAction.execute(
                 %{"action" => "list_directory", "path" => "~", "device" => "Laptop"},
                 owner(ctx)
               )

      assert error =~ ~s(No desktop named "Laptop")
      assert error =~ "Studio Mac"
    end
  end

  describe "the invocation" do
    test "carries the action's fields, its deadline and the turn's correlation id", ctx do
      desktops([@mac], answer({:ok, ok_result(%{})}))
      args = %{"action" => "notify", "title" => "Tea", "body" => "The kettle is on."}

      assert {:ok, %{success: true, output: output}} = DeviceAction.execute(args, owner(ctx))
      assert output == "Showed the notification on your Studio Mac."

      assert_received {:device_action_invoked, "desk-mac-1", "notify", sent, opts}
      assert sent == %{"title" => "Tea", "body" => "The kettle is on."}
      assert opts == [deadline_s: 30, correlation_id: ctx.sid]

      assert_received {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      assert metadata.tool == "device_action"
      assert metadata.action == "notify"
      assert metadata.device_id == "desk-mac-1"
      assert metadata.invocation_id == "inv-test"
      assert metadata.outcome == "ok"
      refute_received {:telemetry, [:fermix, :tool, :exec], _measurements, _second}
    end

    test "a page that is not http or https is refused before anything is sent", ctx do
      desktops([@mac])

      for url <- ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.test/x"] do
        assert {:ok, %{success: false, error: error}} =
                 DeviceAction.execute(%{"action" => "open_url", "url" => url}, owner(ctx))

        assert error =~ "Only an http or https web address"
      end

      refute_received {:device_action_invoked, _id, _action, _args, _opts}
    end

    test "a file reaches the model as its manifest and content part, never in a trace", ctx do
      attachment = %Attachments{
        kind: :document,
        mime_type: "application/pdf",
        name: "lease.pdf",
        size_bytes: byte_size(@pdf),
        bytes: @pdf
      }

      outcome = %{ok_result(%{"name" => "lease.pdf"}) | attachment: attachment}
      desktops([@mac], answer({:ok, outcome}))
      args = %{"action" => "read_file", "path" => "~/Downloads/lease.pdf"}

      assert {:ok, result} = DeviceAction.execute(args, owner(ctx))
      assert result.success
      assert result.output =~ "Read ~/Downloads/lease.pdf from your Studio Mac."
      assert result.output =~ "[attachments]"
      assert result.output =~ "lease.pdf"

      assert result.images == [
               %{type: :document, mime_type: "application/pdf", data: @pdf, name: "lease.pdf"}
             ]

      assert_received {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
      refute inspect(metadata) =~ "Catalog"

      assert_received {:device_action_invoked, _id, "read_file", _args,
                       [deadline_s: 120, correlation_id: _]}
    end

    test "a folder's listing names each entry and says when it was cut", ctx do
      result = %{
        "path" => "/Users/owner/Desktop",
        "entries" => [
          %{"name" => "Plans", "type" => "directory"},
          %{"name" => "notes.txt", "type" => "file", "size_bytes" => 12}
        ],
        "total" => 640,
        "truncated" => true
      }

      desktops([@mac], answer({:ok, ok_result(result)}))

      assert {:ok, %{success: true, output: output}} =
               DeviceAction.execute(
                 %{"action" => "list_directory", "path" => "~/Desktop"},
                 owner(ctx)
               )

      assert output =~ "/Users/owner/Desktop on your Studio Mac holds 640 entries; the first 500:"
      assert output =~ "- Plans/"
      assert output =~ "- notes.txt (12 bytes)"
    end

    test "the desktop's refusal is its own words, and nothing ran", ctx do
      refusal = %{
        "reason" => "protected_path",
        "message" =>
          "/Users/owner/.fermix/auth.json is one Fermix keeps private on this computer."
      }

      desktops([@mac], answer({:ok, %{ok_result(refusal) | status: :refused}}))

      assert {:ok, %{success: false, error: error}} =
               DeviceAction.execute(
                 %{"action" => "read_file", "path" => "~/.fermix/auth.json"},
                 owner(ctx)
               )

      assert error =~ "Your Studio Mac refused to read the file: /Users/owner/.fermix/auth.json"
      assert error =~ "Nothing was run."
    end

    test "a result lost in a reconnect is reported from the receipt, never as run again", ctx do
      reconciled = %{
        kind: :reconciled,
        status: :ok,
        finished_at: "2026-10-27T09:14:05Z",
        invocation_id: "inv-test"
      }

      desktops([@mac], answer({:ok, reconciled}))

      assert {:ok, %{success: true, output: output}} =
               DeviceAction.execute(%{"action" => "list_directory", "path" => "~"}, owner(ctx))

      assert output =~ "finished there (ok) at 2026-10-27T09:14:05Z"
      assert output =~ "It was not run again"

      assert_received {:telemetry, [:fermix, :tool, :exec], _measurements,
                       %{outcome: "reconciled"}}
    end

    test "no result and no receipt is uncertain, and is not sent again", ctx do
      uncertain = %{kind: :uncertain, reason: :no_receipt, invocation_id: "inv-test"}
      desktops([@mac], answer({:ok, uncertain}))

      assert {:ok, %{success: false, error: error}} =
               DeviceAction.execute(
                 %{"action" => "notify", "title" => "a", "body" => "b"},
                 owner(ctx)
               )

      assert error =~ "Whether this notify ran on your Studio Mac is unknown"
      assert error =~ "It was not sent again"
      assert_received {:device_action_invoked, _id, "notify", _args, _opts}
      refute_received {:device_action_invoked, _id, _action, _args, _opts}

      assert_received {:telemetry, [:fermix, :tool, :exec], _measurements,
                       %{outcome: "uncertain"}}
    end

    test "a desktop that has every slot in use is refused before anything runs", ctx do
      desktops([@mac], answer({:error, {:busy, 8}}))

      assert {:ok, %{success: false, error: error}} =
               DeviceAction.execute(%{"action" => "list_directory", "path" => "~"}, owner(ctx))

      assert error =~ "already has 8 actions in progress"
    end

    test "a command never runs without the owner's confirmation of that exact call", ctx do
      desktops([@mac])
      args = %{"action" => "run_command", "command" => "df -h"}

      assert {:ok, %{success: false, error: error}} = DeviceAction.execute(args, owner(ctx))
      assert error =~ "runs only once the owner approves it"

      other =
        AccessGate.digest("device_action", %{args | "command" => "ls"})

      assert {:ok, %{success: false}} =
               DeviceAction.execute(args, owner(ctx, %{access_confirmed: other}))

      refute_received {:device_action_invoked, _id, _action, _args, _opts}
    end

    test "a read grant runs only once confirmed, and says where it may now read", ctx do
      desktops([@mac], answer({:ok, ok_result(%{"path" => "/Users/ana/Downloads"})}))
      args = %{"action" => "grant_read", "path" => "~/Downloads"}

      assert {:ok, %{success: false, error: error}} = DeviceAction.execute(args, owner(ctx))
      assert error =~ "runs only once the owner approves it"
      refute_received {:device_action_invoked, _id, _action, _args, _opts}

      confirmed = owner(ctx, %{access_confirmed: AccessGate.digest("device_action", args)})
      assert {:ok, %{success: true, output: output}} = DeviceAction.execute(args, confirmed)
      assert output =~ "Your Studio Mac now lets Fermix read /Users/ana/Downloads"

      assert_received {:device_action_invoked, "desk-mac-1", "grant_read", sent, opts}
      assert sent == %{"path" => "~/Downloads"}
      assert opts[:deadline_s] == 120
    end

    test "a guest or a cue run is refused even when called directly", ctx do
      desktops([@mac])
      args = %{"action" => "list_directory", "path" => "~"}

      cue_run = owner(ctx) |> Map.delete(:computer_use_origin) |> Map.put(:trigger, "cue")

      for context <- [owner(ctx, %{source_trust: :guest}), cue_run] do
        assert {:ok, %{success: false, error: error}} = DeviceAction.execute(args, context)
        assert error =~ "runs only on a turn the owner asked for"
      end

      refute_received {:device_action_invoked, _id, _action, _args, _opts}
    end
  end

  describe "what the access gate asks" do
    test "only a command or a read grant for a connected desktop that lets actions run", ctx do
      command = %{"action" => "run_command", "command" => "uptime"}

      desktops([@mac])
      assert DeviceAction.approval_required?(command, owner(ctx))

      assert DeviceAction.approval_required?(
               %{"action" => "grant_read", "path" => "~"},
               owner(ctx)
             )

      refute DeviceAction.approval_required?(
               %{"action" => "read_file", "path" => "~"},
               owner(ctx)
             )

      refute DeviceAction.approval_required?(%{"action" => "notify"}, owner(ctx))
      refute DeviceAction.approval_required?(%{command | "command" => ""}, owner(ctx))

      desktops([%{@mac | connected: false}])
      refute DeviceAction.approval_required?(command, owner(ctx))

      desktops([%{@mac | executor: false}])
      refute DeviceAction.approval_required?(command, owner(ctx))
    end

    test "the card names the desktop and the exact command", ctx do
      desktops([@mac])

      request =
        DeviceAction.approval_request(
          %{"action" => "run_command", "command" => "du -sh ~/Downloads", "cwd" => "~"},
          owner(ctx)
        )

      assert request.card == :device
      assert request.head =~ "Studio Mac"

      assert request.lines == [
               {"Computer", "Studio Mac"},
               {"Command", "du -sh ~/Downloads"},
               {"Folder", "~"}
             ]

      assert request.ttl_s == 120
    end

    test "a read grant's card names the desktop and the folder, for the action's deadline",
         ctx do
      desktops([@mac])

      request =
        DeviceAction.approval_request(
          %{"action" => "grant_read", "path" => "~/Downloads/taxes"},
          owner(ctx)
        )

      assert request.card == :device
      assert request.head =~ "Let Fermix read this folder on your Studio Mac?"
      assert request.lines == [{"Computer", "Studio Mac"}, {"Folder", "~/Downloads/taxes"}]
      assert request.ttl_s == 120
    end
  end

  defp ok_result(result),
    do: %{kind: :result, status: :ok, result: result, attachment: nil, invocation_id: "inv-test"}
end
