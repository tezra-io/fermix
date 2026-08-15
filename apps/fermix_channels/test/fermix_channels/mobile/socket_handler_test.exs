defmodule FermixChannels.Mobile.SocketHandlerTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.SocketHandler

  test "only binary frames can enter the Noise state machine" do
    assert {:ok, state} = SocketHandler.init(device_registry: :registry)

    assert {:stop, :unsupported_frame, {1003, "binary frames required"}, ^state} =
             SocketHandler.handle_in({"hello", opcode: :text}, state)
  end

  test "rejects an unknown outer handshake prelude before crypto initialization" do
    assert {:ok, state} = SocketHandler.init(device_registry: :registry)

    assert {:stop, :invalid_prelude, {1002, "invalid mobile prelude"}, ^state} =
             SocketHandler.handle_in({<<"NOPE", 1, 0, 1>>, opcode: :binary}, state)
  end

  test "paired handshake authenticates static identity before waiting for hello" do
    device = %{device_id: "paired-device"}

    state = %{
      phase: :prelude,
      device_store: :store,
      pair_manager: :pair,
      gateway_keypair: :gateway,
      noise_initialize: fn :responder, :ik, static_keypair: :gateway -> {:ok, :noise0} end,
      noise_read: fn :noise0, <<"FXM1", 1, "handshake">> -> {:ok, <<>>, :noise1} end,
      noise_write: fn :noise1, <<>> -> {:ok, "response", :noise2} end,
      noise_remote_static: fn :noise2 -> {:ok, <<7::256>>} end,
      find_device: fn :store, <<7::256>> -> {:ok, device} end
    }

    assert {:push, {:binary, "response"}, next} =
             SocketHandler.handle_in({<<"FXM1", 1, "handshake">>, opcode: :binary}, state)

    assert next.phase == :await_hello
    assert next.authenticated_device == device
    assert next.noise == :noise2
  end

  test "hello must match authenticated identity before registry attachment" do
    hello = %{
      version: 1,
      type: "hello",
      seq: 1,
      payload: %{
        "device_id" => "different-device",
        "app_version" => "1.0",
        "last_server_seq" => 0,
        "protocol_v" => 1
      },
      bytes: <<>>
    }

    state = %{
      phase: :await_hello,
      authenticated_device: %{device_id: "paired-device"},
      device_registry: :registry,
      noise: :noise,
      client_seq: 0,
      max_media_bytes: 20_971_520,
      decrypt: fn :noise, "ciphertext" -> {:ok, "plaintext", :noise1} end,
      decode_client: fn "plaintext", _opts -> {:ok, hello} end
    }

    assert {:stop, :identity_mismatch, {4003, "authenticated device mismatch"}, next} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)

    assert next.noise == :noise1
  end

  test "a reconnect cursor never seeds the per-session transport sequence" do
    test_pid = self()

    hello = %{
      version: 1,
      type: "hello",
      seq: 1,
      payload: %{
        "device_id" => "paired-device",
        "app_version" => "1.0",
        "last_server_seq" => 87,
        "protocol_v" => 1
      },
      bytes: <<>>
    }

    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_hello,
        authenticated_device: %{device_id: "paired-device"},
        device_registry: :registry,
        profile_id: "main",
        noise: :noise,
        client_seq: 0,
        server_seq: 0,
        decrypt: fn :noise, "ciphertext" -> {:ok, "plaintext", :noise1} end,
        decode_client: fn "plaintext", _opts -> {:ok, hello} end,
        update_device: fn _store, "paired-device", %{last_seen: %DateTime{}} ->
          {:ok, %{device_id: "paired-device"}}
        end,
        attach_socket: fn :registry, "paired-device", ^test_pid, profile_id: "main" ->
          :ok
        end,
        hello_ack_builder: fn _state -> {:ok, %{"session_id" => "session"}} end,
        encode_server: fn "hello_ack", %{"session_id" => "session"}, 1 ->
          {:ok, "encoded"}
        end,
        encrypt: fn :noise1, "encoded" -> {:ok, "ciphertext-out", :noise2} end
      })

    assert {:push, {:binary, "ciphertext-out"}, next} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)

    assert next.phase == :ready
    assert next.server_seq == 1
  end

  test "hello_ack advertises the configured media ceiling" do
    hello = %{
      version: 1,
      type: "hello",
      seq: 1,
      payload: %{
        "device_id" => "paired-device",
        "app_version" => "1.0",
        "last_server_seq" => 0,
        "protocol_v" => 1
      },
      bytes: <<>>
    }

    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_hello,
        authenticated_device: %{device_id: "paired-device"},
        device_registry: :registry,
        noise: :noise,
        max_media_bytes: 12_345,
        profile_name: "Orbit",
        wall_clock: fn -> ~U[2026-08-12 19:00:00Z] end,
        decrypt: fn :noise, "ciphertext" -> {:ok, "plaintext", :noise1} end,
        decode_client: fn "plaintext", _opts -> {:ok, hello} end,
        update_device: fn _store, "paired-device", %{last_seen: ~U[2026-08-12 19:00:00Z]} ->
          {:ok, %{device_id: "paired-device"}}
        end,
        attach_socket: fn :registry, "paired-device", _pid, profile_id: "main" -> :ok end,
        history_head: fn "main" -> {:ok, 4} end,
        read_frontier: fn "main" -> {:ok, 3} end,
        discover: fn -> {:ok, []} end,
        encode_server: fn "hello_ack", payload, 1 ->
          assert payload["caps"]["max_media_bytes"] == 12_345
          assert payload["profiles"] == [%{"id" => "main", "name" => "Orbit"}]
          {:ok, "encoded"}
        end,
        encrypt: fn :noise1, "encoded" -> {:ok, "ciphertext-out", :noise2} end
      })

    assert {:push, {:binary, "ciphertext-out"}, next} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)

    assert next.server_seq == 1
  end

  test "authenticated hello persists last_seen before registry attachment" do
    test_pid = self()
    seen_at = ~U[2026-08-12 19:00:00Z]

    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_hello,
        authenticated_device: %{device_id: "paired-device", last_seen: nil},
        device_registry: :registry,
        device_store: :store,
        noise: :noise,
        wall_clock: fn -> seen_at end,
        decrypt: fn :noise, "ciphertext" -> {:ok, "plaintext", :noise1} end,
        decode_client: fn "plaintext", _opts ->
          {:ok,
           %{
             version: 1,
             type: "hello",
             seq: 1,
             payload: %{
               "device_id" => "paired-device",
               "app_version" => "1.0",
               "last_server_seq" => 0,
               "protocol_v" => 1
             },
             bytes: <<>>
           }}
        end,
        update_device: fn :store, "paired-device", %{last_seen: ^seen_at} ->
          send(test_pid, :last_seen_persisted)
          {:ok, %{device_id: "paired-device", last_seen: seen_at}}
        end,
        attach_socket: fn :registry, "paired-device", _pid, profile_id: "main" ->
          assert_receive :last_seen_persisted
          :ok
        end,
        hello_ack_builder: fn _state -> {:ok, %{"session_id" => "session"}} end,
        encode_server: fn "hello_ack", %{"session_id" => "session"}, 1 ->
          {:ok, "encoded"}
        end,
        encrypt: fn :noise1, "encoded" -> {:ok, "ciphertext-out", :noise2} end
      })

    assert {:push, {:binary, "ciphertext-out"}, next} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)

    assert next.authenticated_device.last_seen == seen_at
  end

  test "last_seen persistence failure prevents registry attachment" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_hello,
        authenticated_device: %{device_id: "paired-device"},
        device_registry: :registry,
        noise: :noise,
        wall_clock: fn -> ~U[2026-08-12 19:00:00Z] end,
        decrypt: fn :noise, "ciphertext" -> {:ok, "plaintext", :noise1} end,
        decode_client: fn "plaintext", _opts ->
          {:ok,
           %{
             version: 1,
             type: "hello",
             seq: 1,
             payload: %{
               "device_id" => "paired-device",
               "app_version" => "1.0",
               "last_server_seq" => 0,
               "protocol_v" => 1
             },
             bytes: <<>>
           }}
        end,
        update_device: fn _store, _device_id, _attrs -> {:error, :disk_full} end,
        attach_socket: fn _registry, _device_id, _pid, _opts ->
          send(test_pid, :attached)
          :ok
        end
      })

    assert {:stop, {:last_seen_update_failed, :disk_full}, {1002, "mobile protocol error"}, _} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)

    refute_received :attached
  end

  test "the production decoder enforces the configured media ceiling" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("socket-media-cap")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    store =
      start_supervised!(
        {MediaStore, name: nil, root: root, max_media_bytes: 4, max_store_bytes: 64}
      )

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        media_store: store,
        max_media_bytes: 4,
        noise: :noise,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end,
        encode_server: fn "attach_status", payload, 1 ->
          assert payload["status"] == "upload"
          {:ok, "status"}
        end,
        encrypt: fn :noise, "status" -> {:ok, "encrypted-status", :noise} end
      })

    assert {:arity, 2} = :erlang.fun_info(state.decode_client, :arity)

    assert {:push, {:binary, "encrypted-status"}, accepted} =
             SocketHandler.handle_in(
               {attach_begin_frame("within-cap", 4), opcode: :binary},
               state
             )

    assert accepted.client_seq == 1

    {:ok, oversized_state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        media_store: store,
        max_media_bytes: 4,
        noise: :noise,
        decrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end
      })

    assert {:stop, {:invalid_field, "size_bytes"}, {1002, "mobile protocol error"}, _state} =
             SocketHandler.handle_in(
               {attach_begin_frame("over-cap", 5), opcode: :binary},
               oversized_state
             )
  end

  test "media_fetch uses the durable timeline descriptor for media_begin" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("socket-media-fetch")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    store = start_supervised!({MediaStore, name: nil, root: root, max_store_bytes: 64})
    bytes = "pdf"
    digest = sha256(bytes)

    assert {:ok, ^digest} = MediaStore.put_bytes(store, bytes)

    descriptor = %{
      server_seq: 73,
      media: %{
        "ref" => digest,
        "sha256" => digest,
        "kind" => "document",
        "mime" => "application/pdf",
        "size_bytes" => byte_size(bytes),
        "filename" => "answer.pdf",
        "caption" => "Final answer"
      }
    }

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        profile_id: "work",
        media_store: store,
        noise: :noise,
        negotiated_version: 1,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, "request" -> {:ok, "request", :noise} end,
        decode_client: fn "request", _opts ->
          {:ok,
           %{
             type: "media_fetch",
             version: 1,
             seq: 1,
             payload: %{"ref" => digest},
             bytes: <<>>
           }}
        end,
        media_descriptor: fn "work", ^digest -> {:ok, descriptor} end,
        encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end
      })

    assert {:push, [{:binary, begin_frame}, {:binary, chunk_frame}, {:binary, end_frame}], next} =
             SocketHandler.handle_in({"request", opcode: :binary}, state)

    assert {begin, <<>>} = decode_server_frame(begin_frame)
    assert begin["t"] == "media_begin"
    assert begin["server_seq"] == 73
    assert begin["kind"] == "document"
    assert begin["mime"] == "application/pdf"
    assert begin["size_bytes"] == 3
    assert begin["filename"] == "answer.pdf"
    assert begin["caption"] == "Final answer"

    assert {%{"t" => "media_chunk", "index" => 0}, "pdf"} =
             decode_server_frame(chunk_frame)

    assert {%{"t" => "media_end", "sha256" => ^digest}, <<>>} =
             decode_server_frame(end_frame)

    assert next.client_seq == 1
    assert next.server_seq == 3
  end

  test "a media batch that fails to encode never advances the Noise send cipher" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("socket-media-batch")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    store = start_supervised!({MediaStore, name: nil, root: root, max_store_bytes: 64})
    bytes = "pdf"
    digest = sha256(bytes)

    assert {:ok, ^digest} = MediaStore.put_bytes(store, bytes)

    descriptor = %{
      server_seq: 41,
      media: %{
        "ref" => digest,
        "sha256" => digest,
        "kind" => "document",
        "mime" => "application/pdf",
        "size_bytes" => byte_size(bytes)
      }
    }

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        profile_id: "main",
        media_store: store,
        # The stub cipher is its own nonce: every encryption advances it, so the
        # frame the client finally receives shows exactly how far it moved.
        noise: 0,
        negotiated_version: 1,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn 0, "request" -> {:ok, "request", 0} end,
        decode_client: fn "request", _opts ->
          {:ok,
           %{
             type: "media_fetch",
             version: 1,
             seq: 1,
             payload: %{"ref" => digest},
             bytes: <<>>
           }}
        end,
        media_descriptor: fn "main", ^digest -> {:ok, descriptor} end,
        encode_server: fn
          "media_end", _payload, _seq, _bytes, _version -> {:error, :encoder_unavailable}
          type, _payload, seq, _bytes, _version -> {:ok, "#{type}-#{seq}"}
        end,
        encrypt: fn nonce, plaintext -> {:ok, {nonce, plaintext}, nonce + 1} end
      })

    assert {:push, {:binary, {0, "error-1"}}, next} =
             SocketHandler.handle_in({"request", opcode: :binary}, state)

    assert next.noise == 1
    assert next.server_seq == 1
  end

  test "media_fetch reports an evicted durable blob after consuming the request sequence" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("socket-media-gone")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    store = start_supervised!({MediaStore, name: nil, root: root, max_store_bytes: 64})
    digest = String.duplicate("b", 64)

    descriptor = %{
      server_seq: 19,
      media: %{
        "ref" => digest,
        "sha256" => digest,
        "kind" => "image",
        "mime" => "image/jpeg",
        "size_bytes" => 8
      }
    }

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        profile_id: "main",
        media_store: store,
        noise: :noise,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, "request" -> {:ok, "request", :noise} end,
        decode_client: fn "request", _opts ->
          {:ok,
           %{
             type: "media_fetch",
             version: 1,
             seq: 1,
             payload: %{"ref" => digest},
             bytes: <<>>
           }}
        end,
        media_descriptor: fn "main", ^digest -> {:ok, descriptor} end,
        encode_server: fn "error", payload, 1 ->
          assert payload["code"] == "media_gone"
          {:ok, "gone"}
        end,
        encrypt: fn :noise, "gone" -> {:ok, "encrypted-gone", :noise} end
      })

    assert {:push, {:binary, "encrypted-gone"}, next} =
             SocketHandler.handle_in({"request", opcode: :binary}, state)

    assert next.client_seq == 1
    assert next.server_seq == 1
  end

  test "push registration refuses a token for the other APNs environment" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        push_environment: "production",
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, "ciphertext" -> {:ok, "plaintext", :noise1} end,
        decode_client: fn "plaintext", _opts ->
          {:ok,
           %{
             type: "push_register",
             version: 1,
             seq: 1,
             payload: %{"apns_token" => "token", "environment" => "development"},
             bytes: <<>>
           }}
        end,
        update_device: fn _store, _id, _attrs ->
          send(test_pid, :updated)
          {:ok, %{}}
        end,
        encode_server: fn "error", payload, 1 ->
          assert payload["code"] == "push_environment_mismatch"
          {:ok, "error-frame"}
        end,
        encrypt: fn :noise1, "error-frame" -> {:ok, "encrypted-error", :noise2} end
      })

    assert {:push, {:binary, "encrypted-error"}, next} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)

    refute_received :updated
    assert next.server_seq == 1
  end

  test "push registration stores a token only for the configured APNs environment" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        push_environment: :production,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, "ciphertext" -> {:ok, "plaintext", :noise1} end,
        decode_client: fn "plaintext", _opts ->
          {:ok,
           %{
             type: "push_register",
             version: 1,
             seq: 1,
             payload: %{"apns_token" => "token", "environment" => "production"},
             bytes: <<>>
           }}
        end,
        update_device: fn :store, "paired-device", %{push_token: "token"} ->
          send(test_pid, :updated)
          {:ok, %{}}
        end,
        device_store: :store
      })

    assert {:ok, next} = SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)
    assert_received :updated
    assert next.client_seq == 1
  end

  test "an authenticated application error still consumes its client sequence" do
    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 1,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn
          "first", _opts -> {:ok, %{type: "ping", version: 1, seq: 1, payload: %{}, bytes: <<>>}}
          "second", _opts -> {:ok, %{type: "ping", version: 1, seq: 2, payload: %{}, bytes: <<>>}}
        end,
        event_router: fn
          %{seq: 1}, _context, _opts -> {:error, :busy}
          %{seq: 2}, _context, _opts -> :ok
        end,
        encode_server: fn "error", _payload, 1 -> {:ok, "error-frame"} end,
        encrypt: fn :noise, "error-frame" -> {:ok, "encrypted-error", :noise} end
      })

    assert {:push, {:binary, "encrypted-error"}, state} =
             SocketHandler.handle_in({"first", opcode: :binary}, state)

    assert state.client_seq == 1
    assert {:ok, state} = SocketHandler.handle_in({"second", opcode: :binary}, state)
    assert state.client_seq == 2
  end

  test "the msg pipeline runs off the socket process so control frames keep flowing" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 1,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn
          "msg", _opts -> {:ok, client_msg("c1", 1)}
          "ping", _opts -> {:ok, %{type: "ping", version: 1, seq: 2, payload: %{}, bytes: <<>>}}
        end,
        event_router: fn event, _context, _opts ->
          send(test_pid, {:routed, event.type, self()})
          await_release(event.type)
        end,
        run_request: fn job -> {:ok, spawn(job)} end
      })

    assert {:ok, state} = SocketHandler.handle_in({"msg", opcode: :binary}, state)
    assert_receive {:routed, "msg", worker}
    refute worker == self()

    assert {:ok, state} = SocketHandler.handle_in({"ping", opcode: :binary}, state)
    assert_receive {:routed, "ping", socket}
    assert socket == self()
    assert state.client_seq == 2

    send(worker, :release)
  end

  test "queued requests run one at a time in arrival order" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 1,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn
          "first", _opts -> {:ok, client_msg("c1", 1)}
          "second", _opts -> {:ok, client_msg("c2", 2)}
        end,
        event_router: fn event, _context, _opts ->
          send(test_pid, {:ran, event.payload["client_msg_id"]})
          :ok
        end,
        run_request: fn job ->
          pid = spawn(fn -> receive(do: (:run -> job.())) end)
          send(test_pid, {:launched, pid})
          {:ok, pid}
        end
      })

    assert {:ok, state} = SocketHandler.handle_in({"first", opcode: :binary}, state)
    assert_receive {:launched, first_worker}

    assert {:ok, state} = SocketHandler.handle_in({"second", opcode: :binary}, state)
    refute_receive {:launched, _second_worker}, 50

    send(first_worker, :run)
    assert_receive {:ran, "c1"}
    assert_receive {:DOWN, _ref, :process, ^first_worker, :normal} = down
    assert {:ok, state} = SocketHandler.handle_info(down, state)

    assert_receive {:launched, second_worker}
    send(second_worker, :run)
    assert_receive {:ran, "c2"}
    assert state.pending_requests == []
  end

  test "an asynchronous request failure still reaches the client as a typed error" do
    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 1,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, "msg" -> {:ok, "msg", :noise} end,
        decode_client: fn "msg", _opts -> {:ok, client_msg("c1", 1)} end,
        event_router: fn _event, _context, _opts -> {:error, :busy} end,
        run_request: fn job -> {:ok, spawn(job)} end,
        encode_server: fn "error", payload, 1, <<>>, 1 ->
          assert payload["code"] == "busy"
          {:ok, "error-frame"}
        end,
        encrypt: fn :noise, "error-frame" -> {:ok, "encrypted-error", :noise} end
      })

    assert {:ok, state} = SocketHandler.handle_in({"msg", opcode: :binary}, state)
    assert_receive {:mobile_request_failed, :busy} = failure

    assert {:push, {:binary, "encrypted-error"}, next} = SocketHandler.handle_info(failure, state)
    assert next.server_seq == 1
  end

  test "a worker that dies reports a bounded typed error and starts the next request" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 1,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn <<seq>>, _opts -> {:ok, client_msg("c#{seq}", seq)} end,
        event_router: fn _event, _context, _opts -> :ok end,
        run_request: fn job ->
          pid = spawn(fn -> receive(do: (:run -> job.())) end)
          send(test_pid, {:launched, pid})
          {:ok, pid}
        end,
        encode_server: fn "error", payload, 1, <<>>, 1 ->
          assert payload["code"] == "request_failed"
          send(test_pid, {:error_message, payload["message"]})
          {:ok, "error-frame"}
        end,
        encrypt: fn :noise, "error-frame" -> {:ok, "encrypted-error", :noise} end
      })

    assert {:ok, state} = SocketHandler.handle_in({<<1>>, opcode: :binary}, state)
    assert {:ok, state} = SocketHandler.handle_in({<<2>>, opcode: :binary}, state)
    assert_receive {:launched, worker}

    Process.exit(worker, {:badarg, huge_stacktrace()})
    assert_receive {:DOWN, _ref, :process, ^worker, _reason} = down

    assert {:push, {:binary, "encrypted-error"}, next} = SocketHandler.handle_info(down, state)
    assert_receive {:error_message, message}
    assert String.length(message) <= 512

    # The queue keeps draining after the failure.
    assert_receive {:launched, _next_worker}
    assert next.pending_requests == []
  end

  test "a full request backlog is refused loudly instead of growing without bound" do
    worker = spawn(fn -> receive(do: (:stop -> :ok)) end)
    on_exit(fn -> send(worker, :stop) end)

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 1,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn <<seq>>, _opts -> {:ok, client_msg("c#{seq}", seq)} end,
        event_router: fn _event, _context, _opts -> :ok end,
        run_request: fn _job -> {:ok, worker} end,
        encode_server: fn "error", payload, 1, <<>>, 1 ->
          assert payload["code"] == "request_backlog_full"
          {:ok, "error-frame"}
        end,
        encrypt: fn :noise, "error-frame" -> {:ok, "encrypted-error", :noise} end
      })

    state =
      Enum.reduce(1..33, state, fn seq, state ->
        assert {:ok, next} = SocketHandler.handle_in({<<seq>>, opcode: :binary}, state)
        next
      end)

    assert length(state.pending_requests) == 32

    assert {:push, {:binary, "encrypted-error"}, _next} =
             SocketHandler.handle_in({<<34>>, opcode: :binary}, state)
  end

  test "a repeated hello emits a typed terminal error and closes" do
    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        client_seq: 1,
        decrypt: fn :noise, "second-hello" -> {:ok, "second-hello", :noise} end,
        decode_client: fn "second-hello", _opts ->
          {:ok,
           %{
             type: "hello",
             version: 1,
             seq: 2,
             payload: %{
               "device_id" => "paired-device",
               "app_version" => "1.0",
               "last_server_seq" => 0,
               "protocol_v" => 1
             },
             bytes: <<>>
           }}
        end,
        encode_server: fn "error", payload, 1 ->
          assert payload["code"] == "repeated_hello"
          {:ok, "typed-error"}
        end,
        encrypt: fn :noise, "typed-error" -> {:ok, "encrypted-error", :noise} end
      })

    assert {:stop, :repeated_hello, {1002, "mobile protocol error"},
            [{:binary, "encrypted-error"}], next} =
             SocketHandler.handle_in({"second-hello", opcode: :binary}, state)

    assert next.client_seq == 2
    assert next.server_seq == 1
  end

  test "an unknown authenticated event emits unsupported and closes" do
    unknown = encode_client_frame("future_event", %{}, 1)

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        decrypt: fn :noise, ^unknown -> {:ok, unknown, :noise} end,
        encode_server: fn "error", payload, 1 ->
          assert payload["code"] == "unsupported"
          {:ok, "typed-error"}
        end,
        encrypt: fn :noise, "typed-error" -> {:ok, "encrypted-error", :noise} end
      })

    assert {:stop, {:unknown_event, "future_event"}, {1002, "mobile protocol error"},
            [{:binary, "encrypted-error"}], next} =
             SocketHandler.handle_in({unknown, opcode: :binary}, state)

    assert next.client_seq == 0
    assert next.server_seq == 1
  end

  test "the first application event pins the protocol version for the session" do
    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn
          "first", _opts -> {:ok, %{type: "ping", version: 1, seq: 1, payload: %{}, bytes: <<>>}}
          "second", _opts -> {:ok, %{type: "ping", version: 2, seq: 2, payload: %{}, bytes: <<>>}}
        end,
        event_router: fn _event, _context, _opts -> :ok end
      })

    assert {:ok, state} = SocketHandler.handle_in({"first", opcode: :binary}, state)
    assert state.negotiated_version == 1

    assert {:stop, :protocol_version_mismatch, {1002, "mobile protocol error"}, next} =
             SocketHandler.handle_in({"second", opcode: :binary}, state)

    assert next.client_seq == 1
  end

  test "outbound frames use the pinned session version" do
    state = %{
      phase: :ready,
      noise: :noise,
      server_seq: 0,
      negotiated_version: 7,
      encode_server: fn "pong", %{}, 1, <<>>, 7 -> {:ok, "v7"} end,
      encrypt: fn :noise, "v7" -> {:ok, "ciphertext", :noise} end
    }

    assert {:push, {:binary, "ciphertext"}, next} =
             SocketHandler.handle_info({:mobile_event, %{"t" => "pong"}}, state)

    assert next.server_seq == 1
  end

  test "pairing binds the active window before crypto and counts a failed attempt once" do
    test_pid = self()
    gateway = %{private: <<1::256>>, public: <<2::256>>}

    {:ok, state} =
      SocketHandler.init(%{
        gateway_keypair: gateway,
        pair_manager: :pair,
        current_pair: fn :pair ->
          {:ok, %{session_id: "pair-session", secret: <<1::256>>}}
        end,
        noise_initialize: fn :responder, :ikpsk2, _opts -> {:ok, :noise} end,
        noise_read: fn :noise, _wire -> {:error, :authentication_failed} end,
        record_pair_failure: fn :pair, "pair-session" ->
          send(test_pid, :failure_recorded)
          {:ok, 1}
        end
      })

    assert {:stop, {:pairing_failed, :authentication_failed}, _, stopped} =
             SocketHandler.handle_in({<<"FXM1", 2, "bad">>, opcode: :binary}, state)

    assert stopped.pairing_session_id == "pair-session"
    assert stopped.pair_failure_recorded?
    assert_receive :failure_recorded
    SocketHandler.terminate(:normal, stopped)
    refute_receive :failure_recorded
  end

  test "a pending pairing decision answers keepalive ping instead of closing" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_pair_decision,
        pair_manager: :pair,
        pairing_session_id: "pair-session",
        noise: :noise,
        negotiated_version: 1,
        client_seq: 1,
        decrypt: fn :noise, "ping" -> {:ok, "ping", :noise1} end,
        decode_client: fn "ping", _opts ->
          {:ok, %{type: "ping", version: 1, seq: 2, payload: %{}, bytes: <<>>}}
        end,
        encode_server: fn "pong", %{}, 1, <<>>, 1 -> {:ok, "pong-frame"} end,
        encrypt: fn :noise1, "pong-frame" -> {:ok, "encrypted-pong", :noise2} end,
        record_pair_failure: fn :pair, "pair-session" ->
          send(test_pid, :failure_recorded)
          {:ok, 1}
        end
      })

    assert {:push, {:binary, "encrypted-pong"}, next} =
             SocketHandler.handle_in({"ping", opcode: :binary}, state)

    assert next.phase == :await_pair_decision
    assert next.client_seq == 2
    assert next.server_seq == 1
    refute_received :failure_recorded
  end

  test "a pending pairing decision still refuses any other event" do
    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_pair_decision,
        pair_manager: :pair,
        pairing_session_id: "pair-session",
        noise: :noise,
        negotiated_version: 1,
        client_seq: 1,
        decrypt: fn :noise, "early" -> {:ok, "early", :noise1} end,
        decode_client: fn "early", _opts ->
          {:ok,
           %{
             type: "msg",
             version: 1,
             seq: 2,
             payload: %{"client_msg_id" => "c1", "profile_id" => "main", "text" => "hi"},
             bytes: <<>>
           }}
        end,
        record_pair_failure: fn :pair, "pair-session" -> {:ok, 1} end
      })

    assert {:stop, :pairing_decision_pending, {1002, "mobile protocol error"}, _next} =
             SocketHandler.handle_in({"early", opcode: :binary}, state)
  end

  test "an idle timeout while the owner decides is not a failed pairing handshake" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_pair_decision,
        pair_manager: :pair,
        pairing_session_id: "pair-session",
        record_pair_failure: fn :pair, "pair-session" ->
          send(test_pid, :failure_recorded)
          {:ok, 1}
        end
      })

    assert :ok = SocketHandler.terminate(:timeout, state)
    refute_received :failure_recorded

    assert :ok = SocketHandler.terminate({:error, :closed}, state)
    assert_received :failure_recorded
  end

  test "one-hour Noise lifetime closes cleanly instead of unilateral rekey" do
    test_pid = self()

    state = %{
      phase: :ready,
      noise: %{send_frames: 0},
      server_seq: 0,
      session_started_ms: 0,
      clock: fn -> 3_600_000 end,
      noise_rekey: fn _noise, _direction ->
        send(test_pid, :rekeyed)
        {:ok, %{}}
      end
    }

    assert {:stop, :session_expired, {1000, "Noise session lifetime reached"}, ^state} =
             SocketHandler.handle_info({:mobile_event, %{"t" => "pong"}}, state)

    refute_receive :rekeyed
  end

  test "completed handshake arms an idle lifetime timer and scrubs identity loaders" do
    test_pid = self()
    gateway = %{private: <<1::256>>, public: <<2::256>>}

    {:ok, state} =
      SocketHandler.init(%{
        gateway_keypair: gateway,
        device_store: :store,
        noise_initialize: fn :responder, :ik, static_keypair: ^gateway -> {:ok, :noise0} end,
        noise_read: fn :noise0, <<"FXM1", 1, "handshake">> -> {:ok, <<>>, :noise1} end,
        noise_write: fn :noise1, <<>> -> {:ok, "response", :noise2} end,
        noise_remote_static: fn :noise2 -> {:ok, <<7::256>>} end,
        find_device: fn :store, <<7::256>> -> {:ok, %{device_id: "device"}} end,
        schedule_session_timer: fn message, 3_600_000 ->
          ref = make_ref()
          send(test_pid, {:session_timer, message, ref})
          ref
        end,
        cancel_session_timer: fn ref ->
          send(test_pid, {:session_timer_cancelled, ref})
          :ok
        end
      })

    assert {:push, {:binary, "response"}, next} =
             SocketHandler.handle_in({<<"FXM1", 1, "handshake">>, opcode: :binary}, state)

    assert_receive {:session_timer, {:mobile_session_expired, token}, timer_ref}
    refute Map.has_key?(next, :gateway_keypair)
    refute Map.has_key?(next, :load_gateway_keypair)
    assert next.session_timer_ref == timer_ref

    assert {:stop, :session_expired, {1000, "Noise session lifetime reached"}, expired} =
             SocketHandler.handle_info({:mobile_session_expired, token}, next)

    SocketHandler.terminate(:normal, expired)
    assert_receive {:session_timer_cancelled, ^timer_ref}
  end

  test "a ready frame is authorized immediately before business dispatch" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "revoked-device",
        device_registry: :registry,
        noise: :noise,
        decrypt: fn :noise, "ping" -> {:ok, "ping", :noise} end,
        decode_client: fn "ping", _opts ->
          {:ok, %{type: "ping", version: 1, seq: 1, payload: %{}, bytes: <<>>}}
        end,
        authorize_socket: fn :registry, "revoked-device", ^test_pid ->
          {:error, {:device_not_authorized, {:device_not_found, "revoked-device"}}}
        end,
        event_router: fn _event, _context, _opts ->
          send(test_pid, :dispatched)
          :ok
        end
      })

    assert {:stop, {:socket_not_authorized, _reason}, {1002, "mobile protocol error"}, _state} =
             SocketHandler.handle_in({"ping", opcode: :binary}, state)

    refute_received :dispatched
  end

  test "a replacement notification cleanly closes the old Bandit-owned socket" do
    assert {:ok, state} = SocketHandler.init(device_registry: :registry)

    assert {:stop, :replaced, {4001, "connection replaced"}, ^state} =
             SocketHandler.handle_info({:mobile_replaced, self()}, state)
  end

  test "logical registry fanout is encoded and encrypted by the owning socket" do
    state = %{
      phase: :ready,
      device_id: "device",
      device_registry: :registry,
      noise: :noise,
      server_seq: 4,
      encode_server: fn "notice", %{"kind" => "info", "text" => "done"}, 5 ->
        {:ok, "encoded"}
      end,
      encrypt: fn :noise, "encoded" -> {:ok, "ciphertext", :next_noise} end
    }

    event = %{type: "notice", payload: %{"kind" => "info", "text" => "done"}}

    assert {:push, {:binary, "ciphertext"}, next} =
             SocketHandler.handle_info({:mobile_event, event}, state)

    assert next.noise == :next_noise
    assert next.server_seq == 5
  end

  defp client_msg(client_msg_id, seq) do
    %{
      type: "msg",
      version: 1,
      seq: seq,
      payload: %{
        "client_msg_id" => client_msg_id,
        "profile_id" => "main",
        "text" => "hi",
        "attach_ids" => []
      },
      bytes: <<>>
    }
  end

  defp huge_stacktrace do
    Enum.map(1..40, fn index ->
      {SomeModule, :some_function, 3, [file: String.duplicate("l", 200), line: index]}
    end)
  end

  defp await_release("msg") do
    receive do
      :release -> :ok
    after
      1_000 -> :ok
    end
  end

  defp await_release(_type), do: :ok

  defp attach_begin_frame(attach_id, size_bytes) do
    payload = %{
      "attach_id" => attach_id,
      "kind" => "document",
      "mime" => "application/pdf",
      "size_bytes" => size_bytes,
      "sha256" => String.duplicate("a", 64)
    }

    encode_client_frame("attach_begin", payload, 1)
  end

  defp encode_client_frame(type, payload, seq) do
    header = payload |> Map.merge(%{"v" => 1, "t" => type, "seq" => seq}) |> Jason.encode!()
    <<byte_size(header)::unsigned-big-32, header::binary>>
  end

  defp decode_server_frame(<<header_size::unsigned-big-32, rest::binary>>) do
    <<header::binary-size(header_size), bytes::binary>> = rest
    {Jason.decode!(header), bytes}
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
