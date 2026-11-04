defmodule FermixChannels.Companion.ConnectionAttachmentsTest do
  @moduledoc """
  Companion protocol 7 end to end over a real 0600 Unix socket: the owner's
  hello names the inbox and the largest file the store takes, the app writes
  a file there and sends `attach_file`, the inbox reads it into a real media
  store under a temporary root and removes it before the answer, and a `msg`
  naming it reaches its turn with its attachments while its user's row
  carries their media refs. Each refusal is the inbox's sentence naming the
  attach id, the connection kept; version 6, a connection the daemon started
  and an engine in the device role take no file. Only the Gateway and the
  settlement owner are stand-ins.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Companion.Inbox
  alias FermixChannels.Gateway.Commands.Registry, as: CommandRegistry
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.RequestCoordinator
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.ParentProcess
  alias FermixTestSupport.SafeRm

  @arrival_ms 10_000
  @max_media_bytes 1_024
  @picture "a picture's bytes"
  @picture_sha :crypto.hash(:sha256, @picture) |> Base.encode16(case: :lower)

  defmodule GatewayStub do
    @moduledoc false
    def ingest([message], opts) do
      send(Keyword.fetch!(opts, :agent_server), {:gateway_ingest, message})
      :ok
    end
  end

  defmodule TurnsStub do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:cancel, _profile, _client_msg_id}, _from, test_pid),
      do: {:reply, :ok, test_pid}

    @impl true
    def handle_cast({:settle_unless_handed_off, _key, _attempt, _settlement}, test_pid),
      do: {:noreply, test_pid}
  end

  setup do
    test_pid = self()
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("companion-attach")
    repo = :"companion_attach_repo_#{unique}"
    registry = :"companion_attach_registry_#{unique}"
    connections = :"companion_attach_sup_#{unique}"
    socket_path = Path.join(System.tmp_dir!(), "fx-attach-#{unique}.sock")
    inbox_dir = Path.join(dir, "inbox")

    on_exit(fn ->
      SafeRm.rm_rf!(dir)
      SafeRm.rm(socket_path)
    end)

    queue_owner = start_supervised!({Task, fn -> forward(test_pid) end}, id: :queue_owner)

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({Registry, keys: :duplicate, name: registry})
    store_opts = [repo: repo, agent_id: "agent-a", owner_id: "owner-a"]

    coordinator =
      start_supervised!(
        {RequestCoordinator,
         name: nil,
         boot_epoch: "boot-attach",
         store_opts: [transport: "companion"] ++ store_opts,
         recover?: false}
      )

    turns = start_supervised!({TurnsStub, test_pid})

    store =
      start_supervised!(
        {MediaStore,
         name: nil,
         root: Path.join(dir, "mobile"),
         max_media_bytes: @max_media_bytes,
         max_store_bytes: 64 * 1_024},
        id: :media_store
      )

    inbox = start_supervised!({Inbox, name: nil, dir: inbox_dir, store: store}, id: :inbox)

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    request_opts = [
      store_opts: store_opts,
      request_coordinator: coordinator,
      gateway: GatewayStub,
      agent_server: queue_owner,
      settlement_owner: turns,
      media_server: store,
      engine_role: %{role: :primary, primary: nil}
    ]

    endpoint_opts = [
      name: :"companion_attach_endpoint_#{unique}",
      socket_path: socket_path,
      max_clients: 4,
      connection_supervisor: connections,
      connection_opts: [
        registry: registry,
        request_opts: request_opts,
        primary_epoch: fn -> {:ok, 2} end,
        inbox: inbox
      ]
    ]

    start_supervised!({Endpoint, endpoint_opts})

    %{
      dir: dir,
      endpoint_opts: endpoint_opts,
      inbox_dir: inbox_dir,
      socket_path: socket_path,
      store: store
    }
  end

  describe "the hello" do
    test "the owner's connection is offered the inbox and the store's bound, on either version",
         ctx do
      for version <- [6, 7] do
        client = connect(ctx.socket_path)
        send_line(client, %{"type" => "client_hello", "protocol_version" => version})

        assert recv(client) == %{
                 "type" => "server_hello",
                 "min_version" => 6,
                 "max_version" => 7,
                 "primary_epoch" => 2,
                 "role" => "primary",
                 "commands" => CommandRegistry.catalog(),
                 "attachments" => %{"dir" => ctx.inbox_dir, "max_bytes" => @max_media_bytes}
               }
      end

      assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.stat(ctx.inbox_dir)
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    test "a connection the daemon started is offered the commands and no inbox", ctx do
      restart_endpoint(ctx, daemon_os_pid: ParentProcess.os_pid())
      hello = hello_frame(ctx.socket_path, 7)

      assert hello["commands"] == CommandRegistry.catalog()
      refute Map.has_key?(hello, "attachments")
    end

    test "no inbox is offered while the media store is not running", ctx do
      :ok = stop_supervised(:media_store)
      hello = hello_frame(ctx.socket_path, 7)

      assert hello["commands"] == CommandRegistry.catalog()
      refute Map.has_key?(hello, "attachments")
    end

    test "a connection started with no inbox is offered none", ctx do
      restart_endpoint(ctx, inbox: nil)
      refute Map.has_key?(hello_frame(ctx.socket_path, 7), "attachments")
    end
  end

  describe "attach_file" do
    test "a file in the inbox is stored under its attach id, answered present and removed",
         ctx do
      client = hello(ctx.socket_path, 7)
      path = write_inbox!(ctx, "mac-att-1", @picture)

      send_line(client, attach_file("mac-att-1"))

      assert recv(client) == %{
               "type" => "attach_status",
               "attach_id" => "mac-att-1",
               "status" => "present"
             }

      refute File.exists?(path)

      assert {:ok, %{ref: @picture_sha, kind: "image", mime_type: "image/jpeg"} = stored} =
               MediaStore.attachment(ctx.store, "mac-att-1")

      assert stored.size_bytes == byte_size(@picture)
      assert stored.file_name == "IMG_0412.jpg"
    end

    test "bytes the store already holds are taken without a second copy", ctx do
      client = hello(ctx.socket_path, 7)
      _first = write_inbox!(ctx, "mac-att-1", @picture)
      send_line(client, attach_file("mac-att-1"))
      assert %{"type" => "attach_status"} = recv(client)

      path = write_inbox!(ctx, "mac-att-2", @picture)
      send_line(client, attach_file("mac-att-2"))
      assert %{"type" => "attach_status", "attach_id" => "mac-att-2"} = recv(client)
      refute File.exists?(path)
      assert {:ok, %{ref: @picture_sha}} = MediaStore.attachment(ctx.store, "mac-att-2")
    end

    test "each refusal is the inbox's sentence naming the file, the file removed and the connection kept",
         ctx do
      client = hello(ctx.socket_path, 7)
      large = String.duplicate("x", @max_media_bytes + 1)

      cases = [
        {"too-large", large, %{"size_bytes" => byte_size(large), "sha256" => sha(large)},
         "This file is too large: Fermix takes files of up to 1 KB."},
        {"longer", @picture <> "!", %{},
         "This file changed before Fermix could read it. Attach it again."},
        {"shorter", "a picture", %{},
         "This file changed before Fermix could read it. Attach it again."},
        {"altered", String.replace(@picture, "a", "b"), %{},
         "This file changed before Fermix could read it. Attach it again."}
      ]

      log =
        capture_log(fn ->
          for {id, bytes, overrides, sentence} <- cases do
            path = write_inbox!(ctx, id, bytes)
            send_line(client, Map.merge(attach_file(id), overrides))
            assert recv(client) == refusal(id, sentence), id
            refute File.exists?(path), id
            assert {:error, :unknown_attachment} = MediaStore.attachment(ctx.store, id)
          end
        end)

      assert log =~ "refused attachment too-large"
      assert_open(client)
    end

    test "a missing file, a symlink and a name already taken are refused by name", ctx do
      client = hello(ctx.socket_path, 7)
      outside = Path.join(ctx.dir, "outside.jpg")
      File.write!(outside, @picture)
      link = Path.join(ctx.inbox_dir, "linked")
      :ok = File.ln_s(outside, link)

      capture_log(fn ->
        send_line(client, attach_file("missing"))

        assert recv(client) ==
                 refusal("missing", "Fermix found no file to take. Attach it again.")

        send_line(client, attach_file("linked"))

        assert recv(client) ==
                 refusal(
                   "linked",
                   "Fermix takes only a plain file the app saved for it. Attach it again."
                 )

        assert {:error, :enoent} = File.lstat(link)
        assert File.read!(outside) == @picture

        _path = write_inbox!(ctx, "taken", @picture)
        send_line(client, attach_file("taken"))
        assert %{"type" => "attach_status"} = recv(client)
        again = write_inbox!(ctx, "taken", @picture)
        send_line(client, attach_file("taken"))

        assert recv(client) ==
                 refusal("taken", "Fermix already has a file under this name. Attach it again.")

        refute File.exists?(again)
      end)

      assert_open(client)
    end

    test "a store with no room for the file refuses it", ctx do
      small = start_small_store!(ctx)
      restart_endpoint(ctx, inbox: small.inbox, request_opts_media: small.store)
      client = hello(ctx.socket_path, 7)
      bytes = String.duplicate("y", 600)
      path = write_inbox!(%{inbox_dir: small.dir}, "roomless", bytes)

      capture_log(fn ->
        send_line(client, %{attach_file("roomless") | "size_bytes" => 600, "sha256" => sha(bytes)})

        assert recv(client) ==
                 refusal(
                   "roomless",
                   "Fermix has no room for this file right now. Try a smaller one."
                 )
      end)

      refute File.exists?(path)
    end

    test "with the media store down the file is refused and removed", ctx do
      client = hello(ctx.socket_path, 7)
      :ok = stop_supervised(:media_store)
      path = write_inbox!(ctx, "mac-att-1", @picture)

      capture_log(fn ->
        send_line(client, attach_file("mac-att-1"))

        assert recv(client) ==
                 refusal("mac-att-1", "Fermix cannot take files right now. Try again later.")
      end)

      refute File.exists?(path)
      assert_open(client)
    end

    test "a connection the daemon started is refused, and its file removed unread", ctx do
      restart_endpoint(ctx, daemon_os_pid: ParentProcess.os_pid())
      client = hello(ctx.socket_path, 7)
      path = write_inbox!(ctx, "mac-att-1", @picture)

      capture_log(fn ->
        send_line(client, attach_file("mac-att-1"))

        assert recv(client) ==
                 refusal("mac-att-1", "Only the owner's own Fermix app can attach files.")
      end)

      refute File.exists?(path)
      assert {:error, :unknown_attachment} = MediaStore.attachment(ctx.store, "mac-att-1")
      assert_open(client)
    end

    test "an engine in the device role refuses it by name and writes nothing", ctx do
      restart_endpoint(ctx,
        engine_role: %{role: :device, primary: "aws i-0f3b1c"},
        move_in_progress: fn -> :none end
      )

      client = hello(ctx.socket_path, 7)
      path = write_inbox!(ctx, "mac-att-1", @picture)

      send_line(client, attach_file("mac-att-1"))

      assert recv(client) ==
               refusal(
                 "mac-att-1",
                 "This engine runs in the device role; the primary is aws i-0f3b1c."
               )

      refute File.exists?(path)
      assert {:error, :unknown_attachment} = MediaStore.attachment(ctx.store, "mac-att-1")
    end

    test "a version 6 connection does not have attach_file", ctx do
      client = hello(ctx.socket_path, 6)
      path = write_inbox!(ctx, "mac-att-1", @picture)

      send_line(client, attach_file("mac-att-1"))

      assert recv(client) == %{
               "type" => "error",
               "reason" => "unknown_event",
               "event" => "attach_file"
             }

      assert closed?(client)
      assert {:error, :unknown_attachment} = MediaStore.attachment(ctx.store, "mac-att-1")
      assert File.exists?(path)
    end
  end

  describe "a message naming files" do
    test "reaches its turn with its attachments, and its row carries their media refs", ctx do
      client = hello(ctx.socket_path, 7)
      watcher = hello(ctx.socket_path, 6)
      _path = write_inbox!(ctx, "mac-att-1", @picture)
      send_line(client, attach_file("mac-att-1"))
      assert %{"type" => "attach_status"} = recv(client)

      send_line(client, message("mac-40", "", ["mac-att-1"]))
      assert %{"type" => "accepted", "client_msg_id" => "mac-40"} = recv(client)

      ref = %{
        "ref" => @picture_sha,
        "kind" => "image",
        "mime" => "image/jpeg",
        "size_bytes" => byte_size(@picture),
        "filename" => "IMG_0412.jpg"
      }

      for socket <- [client, watcher] do
        assert %{
                 "type" => "row",
                 "role" => "user",
                 "kind" => "media",
                 "text" => "",
                 "client_msg_id" => "mac-40",
                 "media_refs" => [^ref]
               } = recv(socket)
      end

      assert_receive {:gateway_ingest, message}, @arrival_ms

      assert [
               %{
                 file_id: "mac-att-1",
                 hint: :photo,
                 mime_type: "image/jpeg",
                 file_name: "IMG_0412.jpg"
               } = declared
             ] = message.attachments

      assert declared.size_bytes == byte_size(@picture)
      assert message.channel == "companion"
    end

    test "a file the store no longer holds fails the message by its id, the connection kept",
         ctx do
      client = hello(ctx.socket_path, 7)

      send_line(client, message("mac-41", "look", ["never-taken"]))
      assert %{"type" => "accepted", "client_msg_id" => "mac-41"} = recv(client)

      assert recv(client) == %{
               "type" => "error",
               "reason" => "request_failed",
               "message" => "Fermix no longer has a file this message names. Attach it again.",
               "client_msg_id" => "mac-41"
             }

      refute_received {:gateway_ingest, _message}
      assert_open(client)
    end

    test "is refused on version 6 and from a connection the daemon started", ctx do
      old = hello(ctx.socket_path, 6)
      send_line(old, message("mac-42", "look", ["mac-att-1"]))
      assert %{"type" => "error", "reason" => "attachments_unsupported"} = recv(old)
      assert closed?(old)

      restart_endpoint(ctx, daemon_os_pid: ParentProcess.os_pid())
      agent = hello(ctx.socket_path, 7)
      send_line(agent, message("agent-1", "look", ["mac-att-1"]))
      assert %{"type" => "error", "reason" => "attachments_unsupported"} = recv(agent)
      assert closed?(agent)
      refute_received {:gateway_ingest, _message}
    end
  end

  # -- helpers --------------------------------------------------------------------

  defp attach_file(id) do
    %{
      "type" => "attach_file",
      "attach_id" => id,
      "kind" => "image",
      "mime" => "image/jpeg",
      "size_bytes" => byte_size(@picture),
      "sha256" => @picture_sha,
      "name" => "IMG_0412.jpg"
    }
  end

  defp refusal(id, sentence),
    do: %{
      "type" => "error",
      "reason" => "request_failed",
      "message" => sentence,
      "attach_id" => id
    }

  defp message(id, text, attach_ids) do
    %{
      "type" => "msg",
      "client_msg_id" => id,
      "profile_id" => "main",
      "text" => text,
      "attach_ids" => attach_ids
    }
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # As the app writes it: the whole file, owner-only, before it sends.
  defp write_inbox!(%{inbox_dir: dir}, id, bytes) do
    path = Path.join(dir, id)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    path
  end

  # A store smaller than its largest file, and its own inbox, so a file that
  # passes the size bound still finds no room.
  defp start_small_store!(ctx) do
    dir = Path.join(ctx.dir, "small-inbox")

    store =
      start_supervised!(
        {MediaStore,
         name: nil,
         root: Path.join(ctx.dir, "small"),
         max_media_bytes: 1_024,
         max_store_bytes: 512},
        id: :small_store
      )

    inbox = start_supervised!({Inbox, name: nil, dir: dir, store: store}, id: :small_inbox)
    %{dir: dir, store: store, inbox: inbox}
  end

  # The endpoint again, its connections started with `changes`: connection
  # options, or `engine_role:` and `request_opts_media:` for the request path.
  defp restart_endpoint(ctx, changes) do
    stop_supervised!(Endpoint)
    {role, changes} = Keyword.pop(changes, :engine_role)
    {media, changes} = Keyword.pop(changes, :request_opts_media)

    connection_opts =
      ctx.endpoint_opts
      |> Keyword.fetch!(:connection_opts)
      |> Keyword.merge(changes)
      |> Keyword.update!(:request_opts, &request_opts(&1, role, media))

    ctx.endpoint_opts
    |> Keyword.put(:connection_opts, connection_opts)
    |> then(&start_supervised!({Endpoint, &1}))
  end

  defp request_opts(opts, role, media) do
    opts
    |> then(&if(role, do: Keyword.put(&1, :engine_role, role), else: &1))
    |> then(&if(media, do: Keyword.put(&1, :media_server, media), else: &1))
  end

  defp assert_open(client) do
    send_line(client, %{"type" => "read_state", "profile_id" => "main", "read_up_to_seq" => 0})
    assert %{"type" => "read_state"} = recv(client)
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

  defp hello_frame(path, version) do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => version})
    assert %{"type" => "server_hello"} = frame = recv(client)
    frame
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        active: false,
        packet: :line,
        buffer: 128 * 1_024
      ])

    socket
  end

  defp send_line(socket, map), do: :ok = :gen_tcp.send(socket, Jason.encode!(map) <> "\n")

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, @arrival_ms)
    Jason.decode!(line)
  end

  defp closed?(socket), do: :gen_tcp.recv(socket, 0, @arrival_ms) == {:error, :closed}
end
