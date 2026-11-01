defmodule FermixChannels.Companion.ConnectionChecklistsTest do
  @moduledoc """
  MILESTONE_85 §07, companion protocol 6, end to end over a real 0600 Unix
  socket and a throwaway repo: the owner's Mac pulls the index and its lists,
  holds at most 16, edits by row id through the same transaction the model
  uses, once per `client_msg_id`, and every holder hears each committed change
  as the whole list, at most once per window per list, whoever made it. A
  connection the daemon started reads and changes nothing, and a turn says it
  draws lists only when its connection pulled the index. Every version in the
  window, {6, 7}, has the lists.

  Most tests deliver the coalescing window's end by hand (`flush!/1`), so no
  assertion races a clock; one keeps the real 100 ms window.
  """
  use ExUnit.Case, async: true

  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.ChecklistNotifier
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Checklists.Registry, as: ChecklistRegistry
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.ParentProcess

  # A line's arrival over the socket on a loaded runner.
  @arrival_ms 10_000
  # A window no test outlives: its end comes from `flush!/1`.
  @manual_window_ms 600_000

  @owner_turn %{
    agent_name: "main",
    conversation_key: {"companion", "main", :root},
    source_trust: :operator,
    computer_use_origin: :interactive,
    channel: "companion",
    outside_sources: MapSet.new()
  }

  defmodule GatewayStub do
    def ingest([message], opts) do
      send(Keyword.fetch!(opts, :agent_server), {:gateway_ingest, message})
      :ok
    end
  end

  setup do
    test_pid = self()
    unique = System.unique_integer([:positive])
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("companion-lists")
    repo = :"companion_lists_repo_#{unique}"
    registry = :"companion_lists_registry_#{unique}"
    connections = :"companion_lists_sup_#{unique}"
    socket_path = Path.join(System.tmp_dir!(), "fermix-clists-#{unique}.sock")

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf!(dir)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    queue_owner = start_supervised!({Task, fn -> forward(test_pid) end}, id: :queue_owner)

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({Registry, keys: :duplicate, name: registry})
    store_opts = [repo: repo, agent_id: "agent-l", owner_id: "owner-l"]

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil,
         boot_epoch: "boot-lists",
         store_opts: [transport: "companion"] ++ store_opts,
         recover?: false}
      )

    approvals =
      start_supervised!(
        {Approvals,
         name: nil,
         schedule: fn _message, _delay -> make_ref() end,
         announce: fn _profile, _card, _transport -> :ok end}
      )

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    notifier = &ChecklistNotifier.changed(&1, registry)
    checklist_opts = [repo: repo, notifier: notifier]

    endpoint_opts = [
      name: :"companion_lists_endpoint_#{unique}",
      socket_path: socket_path,
      max_clients: 4,
      connection_supervisor: connections,
      connection_opts: [
        registry: registry,
        approvals: approvals,
        checklist_opts: checklist_opts,
        checklist_window_ms: @manual_window_ms,
        request_opts: [
          store_opts: store_opts,
          request_coordinator: coordinator,
          gateway: GatewayStub,
          agent_server: queue_owner,
          engine_role: %{role: :primary, primary: nil}
        ],
        primary_epoch: fn -> {:ok, 2} end
      ]
    ]

    start_supervised!({Endpoint, endpoint_opts})

    %{
      socket_path: socket_path,
      registry: registry,
      repo: repo,
      checklist_opts: checklist_opts,
      endpoint_opts: endpoint_opts
    }
  end

  # --- what the model makes and the device reads -------------------------------------

  defp model_edit!(ctx, changes) do
    {:ok, _answer} =
      ChecklistRegistry.edit(%{"changes" => changes}, @owner_turn, ctx.checklist_opts)
  end

  defp groceries!(ctx) do
    model_edit!(ctx, [
      %{
        "list" => "Groceries",
        "ops" => [
          %{"op" => "create"},
          %{"op" => "section", "text" => "Produce"},
          %{"op" => "add", "text" => "Lemons"},
          %{"op" => "add", "text" => "Rice"}
        ]
      }
    ])

    {:ok, [list]} = ChecklistRegistry.device_index(:independent, ctx.checklist_opts)
    list.id
  end

  defp pull_index(client) do
    send_line(client, %{"type" => "checklists_pull", "profile_id" => "main"})
    assert %{"type" => "checklists", "profile_id" => "main", "lists" => lists} = recv(client)
    lists
  end

  defp pull(client, list_id, removed \\ nil) do
    pull = %{"type" => "checklist_pull", "profile_id" => "main", "list_id" => list_id}
    send_line(client, if(removed, do: Map.put(pull, "removed", true), else: pull))
    assert %{"type" => "checklist", "profile_id" => "main", "list" => list} = recv(client)
    list
  end

  defp edit(client, id, list_id, op) do
    payload = %{
      "type" => "checklist_edit",
      "client_msg_id" => id,
      "profile_id" => "main",
      "op" => op
    }

    send_line(client, if(list_id, do: Map.put(payload, "list_id", list_id), else: payload))
  end

  defp accepted!(client, id, duplicate \\ false) do
    assert %{"type" => "accepted", "client_msg_id" => ^id, "duplicate" => ^duplicate} =
             recv(client)
  end

  defp row_id(list, text), do: Enum.find(list["rows"], &(&1["text"] == text))["row_id"]

  # The coalescing window's end, delivered to every connection of this test.
  defp flush!(registry) do
    for {pid, _version} <- Registry.lookup(registry, "main"), do: send(pid, :checklists_flush)
    :ok
  end

  # --- pulling ---------------------------------------------------------------------

  test "the owner's version 6 connection pulls the index and a whole list", ctx do
    list_id = groceries!(ctx)
    client = hello(ctx.socket_path, 6)

    assert [index] = pull_index(client)

    assert index == %{
             "list_id" => list_id,
             "title" => "Groceries",
             "open" => 2,
             "done" => 0,
             "rev" => 1
           }

    list = pull(client, list_id)
    assert %{"list_id" => ^list_id, "title" => "Groceries", "rev" => 1, "rows" => rows} = list

    assert [
             %{"kind" => "section", "text" => "Produce", "row_id" => "ci_" <> _},
             %{"kind" => "item", "text" => "Lemons", "done" => false},
             %{"kind" => "item", "text" => "Rice", "done" => false}
           ] = rows

    refute Map.has_key?(list, "removed")
  end

  # --- one edit, every holder --------------------------------------------------------

  test "two connections that hold a list both hear one edit, as the whole list", ctx do
    list_id = groceries!(ctx)
    mac = hello(ctx.socket_path, 6)
    other = hello(ctx.socket_path, 6)
    lemons = mac |> pull(list_id) |> row_id("Lemons")
    _ = pull(other, list_id)

    edit(mac, "tick-1", list_id, %{"op" => "check", "row_id" => lemons})
    accepted!(mac, "tick-1")
    flush!(ctx.registry)

    for client <- [mac, other] do
      assert %{"type" => "checklist", "list" => %{"rev" => 2, "rows" => rows}} = recv(client)
      assert %{"done" => true, "done_at" => _} = Enum.find(rows, &(&1["row_id"] == lemons))
    end
  end

  test "the real window pushes a change once it ends", ctx do
    list_id = groceries!(ctx)
    restart_endpoint(ctx, checklist_window_ms: 100)
    mac = hello(ctx.socket_path, 6)
    rice = mac |> pull(list_id) |> row_id("Rice")

    edit(mac, "tick-2", list_id, %{"op" => "check", "row_id" => rice})
    accepted!(mac, "tick-2")

    assert %{"type" => "checklist", "list" => %{"rev" => 2}} = recv(mac)
  end

  test "several edits inside one window give one push carrying the final rev", ctx do
    list_id = groceries!(ctx)
    mac = hello(ctx.socket_path, 6)
    list = pull(mac, list_id)

    for {text, n} <- [{"Lemons", 1}, {"Rice", 2}] do
      edit(mac, "tick-#{n}", list_id, %{"op" => "check", "row_id" => row_id(list, text)})
      accepted!(mac, "tick-#{n}")
    end

    edit(mac, "add-1", list_id, %{"op" => "add", "text" => "Eggs"})
    accepted!(mac, "add-1")
    flush!(ctx.registry)

    assert %{"type" => "checklist", "list" => %{"rev" => 4, "rows" => rows}, "made" => made} =
             recv(mac)

    assert made == %{"add-1" => row_id(%{"rows" => rows}, "Eggs")}

    # Nothing else was pending: the next line answers the next request.
    send_line(mac, %{"type" => "checklists_pull", "profile_id" => "main"})
    assert %{"type" => "checklists"} = recv(mac)
  end

  test "an edit sent again by its client_msg_id is a duplicate that changes nothing", ctx do
    list_id = groceries!(ctx)
    mac = hello(ctx.socket_path, 6)
    _ = pull(mac, list_id)

    edit(mac, "add-eggs", list_id, %{"op" => "add", "text" => "Eggs"})
    accepted!(mac, "add-eggs")
    flush!(ctx.registry)
    assert %{"type" => "checklist", "list" => %{"rev" => 2} = list, "made" => made} = recv(mac)

    # A reconnect replays its outbox.
    again = hello(ctx.socket_path, 6)
    _ = pull(again, list_id)
    edit(again, "add-eggs", list_id, %{"op" => "add", "text" => "Eggs"})
    accepted!(again, "add-eggs", true)
    flush!(ctx.registry)

    assert %{"type" => "checklist", "list" => %{"rev" => 2, "rows" => rows}, "made" => ^made} =
             recv(again)

    assert Enum.count(rows, &(&1["text"] == "Eggs")) == 1
    assert made == %{"add-eggs" => row_id(list, "Eggs")}
  end

  test "a model's edit reaches the connection that holds the list", ctx do
    list_id = groceries!(ctx)
    mac = hello(ctx.socket_path, 6)
    _ = pull(mac, list_id)
    _ = pull_index(mac)

    model_edit!(ctx, [%{"list" => "Groceries", "ops" => [%{"op" => "add", "text" => "Oat milk"}]}])

    flush!(ctx.registry)

    pushes = [recv(mac), recv(mac)]

    assert %{"list" => %{"rev" => 2, "rows" => rows}} =
             Enum.find(pushes, &(&1["type"] == "checklist"))

    assert Enum.any?(rows, &(&1["text"] == "Oat milk"))
    refute Map.has_key?(Enum.find(pushes, &(&1["type"] == "checklist")), "made")

    assert %{"lists" => [%{"open" => 3, "rev" => 2}]} =
             Enum.find(pushes, &(&1["type"] == "checklists"))
  end

  # --- holding ---------------------------------------------------------------------

  test "a connection holds at most 16 lists, letting the oldest go", ctx do
    changes = for i <- 1..17, do: %{"list" => "List #{i}", "ops" => [%{"op" => "create"}]}
    for batch <- Enum.chunk_every(changes, 8), do: model_edit!(ctx, batch)
    {:ok, lists} = ChecklistRegistry.device_index(:independent, ctx.checklist_opts)
    ids = Enum.map(lists, & &1.id)
    mac = hello(ctx.socket_path, 6)
    for id <- ids, do: pull(mac, id)

    model_edit!(ctx, [
      %{"list" => "List 1", "ops" => [%{"op" => "add", "text" => "let go"}]},
      %{"list" => "List 17", "ops" => [%{"op" => "add", "text" => "held"}]}
    ])

    flush!(ctx.registry)
    held = List.last(ids)
    assert %{"type" => "checklist", "list" => %{"list_id" => ^held}} = recv(mac)

    send_line(mac, %{"type" => "checklists_pull", "profile_id" => "main"})
    assert %{"type" => "checklists"} = recv(mac)
  end

  # --- the ops only a device sends -------------------------------------------------

  test "clear_done removes every done item, and Recently removed shows them", ctx do
    list_id = groceries!(ctx)
    mac = hello(ctx.socket_path, 6)
    list = pull(mac, list_id)

    for {text, n} <- [{"Lemons", 1}, {"Rice", 2}] do
      edit(mac, "tick-#{n}", list_id, %{"op" => "check", "row_id" => row_id(list, text)})
      accepted!(mac, "tick-#{n}")
    end

    edit(mac, "clear", list_id, %{"op" => "clear_done"})
    accepted!(mac, "clear")
    flush!(ctx.registry)

    assert %{"type" => "checklist", "list" => %{"rows" => [%{"kind" => "section"}]}} = recv(mac)
    assert %{"removed" => removed} = pull(mac, list_id, true)
    assert Enum.sort(Enum.map(removed, & &1["text"])) == ["Lemons", "Rice"]
    assert Enum.all?(removed, &is_binary(&1["removed_at"]))
  end

  test "restore brings a row back at its place, and a list back unless its title is in use",
       ctx do
    list_id = groceries!(ctx)
    mac = hello(ctx.socket_path, 6)
    lemons = mac |> pull(list_id) |> row_id("Lemons")

    edit(mac, "rm-1", list_id, %{"op" => "remove", "row_id" => lemons})
    accepted!(mac, "rm-1")
    edit(mac, "back-1", list_id, %{"op" => "restore", "row_id" => lemons})
    accepted!(mac, "back-1")

    assert ["Produce", "Lemons", "Rice"] =
             mac |> pull(list_id) |> Map.fetch!("rows") |> Enum.map(& &1["text"])

    edit(mac, "rm-list", list_id, %{"op" => "remove_list"})
    accepted!(mac, "rm-list")
    assert %{"removed_at" => _} = pull(mac, list_id)
    edit(mac, "new-list", nil, %{"op" => "create", "title" => "groceries"})
    accepted!(mac, "new-list")

    edit(mac, "back-2", list_id, %{"op" => "restore"})

    assert %{
             "type" => "error",
             "reason" => "request_failed",
             "client_msg_id" => "back-2",
             "message" => message
           } =
             next_answer(mac)

    assert message ==
             ~s(Another list is named "Groceries" now, so this one cannot come back under that ) <>
               "name; restore it with a new title, or rename the other list first."

    edit(mac, "back-3", list_id, %{"op" => "restore", "title" => "Groceries, old"})
    accepted!(mac, "back-3")

    titles = mac |> pull_index() |> Enum.map(& &1["title"]) |> Enum.sort()
    assert titles == ["Groceries, old", "groceries"]
  end

  test "a refused edit is request_failed with the engine's sentence, the connection kept", ctx do
    list_id = groceries!(ctx)
    mac = hello(ctx.socket_path, 6)

    edit(mac, "bad", list_id, %{"op" => "check", "row_id" => "ci_0000000000"})

    assert %{
             "type" => "error",
             "reason" => "request_failed",
             "client_msg_id" => "bad",
             "message" => message
           } =
             recv(mac)

    assert message == "That row is not in this list any more; pull the list again."

    # A refusal names what the device sent, never the model's fields.
    [section, row | _rest] = pull(mac, list_id)["rows"]

    for {id, target, op, sentence} <- [
          {"gone", "ck_0000000000", %{"op" => "clear_done"},
           "No list has that id; it may have been removed more than 30 days ago."},
          {"nowhere", list_id, %{"op" => "move", "row_id" => row["row_id"]},
           "A move needs a section_id, an after_id or a to_list_id."},
          {"both", list_id,
           %{
             "op" => "add",
             "text" => "Basil",
             "section_id" => section["row_id"],
             "after_id" => row["row_id"]
           }, "Give section_id or after_id, not both."},
          {"same", list_id, %{"op" => "move", "row_id" => row["row_id"], "to_list_id" => list_id},
           "to_list_id names the list the row is already in."}
        ] do
      edit(mac, id, target, op)

      assert %{"type" => "error", "reason" => "request_failed", "client_msg_id" => ^id} =
               refusal = recv(mac)

      assert refusal["message"] == sentence
    end

    assert [_list] = pull_index(mac)
  end

  # --- who may --------------------------------------------------------------------

  test "a connection the daemon started reads and changes no list", ctx do
    list_id = groceries!(ctx)
    restart_endpoint(ctx, daemon_os_pid: ParentProcess.os_pid())
    agent = hello(ctx.socket_path, 6)
    sentence = "Only the owner's own Fermix app can read or change the owner's lists."

    send_line(agent, %{"type" => "checklists_pull", "profile_id" => "main"})

    assert %{"type" => "error", "reason" => "request_failed", "message" => ^sentence} =
             recv(agent)

    edit(agent, "agent-1", list_id, %{"op" => "remove_list"})

    assert %{
             "type" => "error",
             "reason" => "request_failed",
             "client_msg_id" => "agent-1",
             "message" => ^sentence
           } =
             recv(agent)

    assert {:ok, [_still_there]} =
             ChecklistRegistry.device_index(:independent, ctx.checklist_opts)
  end

  # M75: a device-role engine runs a retired copy of a moved home, so an edit
  # from it is refused by its id and changes nothing; the lists are still read.
  test "a device-role engine refuses an edit by its id and still serves the pulls", ctx do
    list_id = groceries!(ctx)
    request_opts = ctx.endpoint_opts[:connection_opts][:request_opts]
    role = %{role: :device, primary: "vm.example.test"}
    restart_endpoint(ctx, request_opts: Keyword.put(request_opts, :engine_role, role))
    mac = hello(ctx.socket_path, 6)

    edit(mac, "device-1", list_id, %{"op" => "remove_list"})

    assert recv(mac) == %{
             "type" => "error",
             "reason" => "request_failed",
             "message" => "This engine runs in the device role; the primary is vm.example.test.",
             "client_msg_id" => "device-1"
           }

    assert [%{"list_id" => ^list_id}] = pull_index(mac)
    assert %{"list_id" => ^list_id} = pull(mac, list_id)
  end

  # --- the card line --------------------------------------------------------------

  test "a turn draws lists only when its connection pulled the index", ctx do
    _ = groceries!(ctx)
    drawing = hello(ctx.socket_path, 6)
    _ = pull_index(drawing)
    plain = hello(ctx.socket_path, 6)

    for {client, id} <- [{drawing, "draw-1"}, {plain, "plain-1"}] do
      send_line(client, %{
        "type" => "msg",
        "client_msg_id" => id,
        "profile_id" => "main",
        "text" => "hi",
        "attach_ids" => []
      })

      {before, accepted} = until_frame(client, "accepted")
      assert %{"client_msg_id" => ^id} = accepted
      assert Enum.all?(before, &(&1["type"] == "row")), inspect(before)
    end

    messages =
      for _n <- 1..2 do
        assert_receive {:gateway_ingest, message}, @arrival_ms
        {message.id, Map.get(message.metadata, :draws_lists)}
      end

    assert Enum.sort(messages) == [{"draw-1", true}, {"plain-1", nil}]
  end

  # --- plumbing -------------------------------------------------------------------

  # The answer to a request, past any push that arrived before it.
  defp next_answer(client) do
    case recv(client) do
      %{"type" => type} when type in ["checklist", "checklists"] -> next_answer(client)
      line -> line
    end
  end

  # Every line up to the first of `type`, and that one: a turn's rows reach
  # every connection, so another's can come first.
  defp until_frame(client, type, seen \\ []) when length(seen) < 20 do
    case recv(client) do
      %{"type" => ^type} = frame -> {Enum.reverse(seen), frame}
      line -> until_frame(client, type, [line | seen])
    end
  end

  defp restart_endpoint(ctx, connection_opts) do
    stop_supervised!(Endpoint)

    ctx.endpoint_opts
    |> Keyword.update!(:connection_opts, &Keyword.merge(&1, connection_opts))
    |> then(&start_supervised!({Endpoint, &1}))
  end

  defp forward(test_pid) do
    receive do
      message -> send(test_pid, message)
    end

    forward(test_pid)
  end

  defp hello(path, version) do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => version})
    assert %{"type" => "server_hello"} = recv(client)
    client
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        active: false,
        packet: :line,
        buffer: 256 * 1_024
      ])

    socket
  end

  defp send_line(socket, map), do: :ok = :gen_tcp.send(socket, Jason.encode!(map) <> "\n")

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, @arrival_ms)
    Jason.decode!(line)
  end
end
