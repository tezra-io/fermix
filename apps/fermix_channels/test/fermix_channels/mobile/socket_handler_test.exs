defmodule FermixChannels.Mobile.SocketHandlerTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Discovery
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.SocketHandler
  alias FermixChannels.Mobile.TlsTransport

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
      version: 2,
      type: "hello",
      seq: 1,
      payload: %{
        "device_id" => "different-device",
        "app_version" => "1.0",
        "last_server_seq" => 0,
        "protocol_v" => 2
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
      version: 2,
      type: "hello",
      seq: 1,
      payload: %{
        "device_id" => "paired-device",
        "app_version" => "1.0",
        "last_server_seq" => 87,
        "protocol_v" => 2
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
      version: 2,
      type: "hello",
      seq: 1,
      payload: %{
        "device_id" => "paired-device",
        "app_version" => "1.0",
        "last_server_seq" => 0,
        "protocol_v" => 2
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
          # Every turn a request opens ends on this wire (mobile protocol 2).
          assert payload["caps"]["turn_done"] == true
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
             version: 2,
             type: "hello",
             seq: 1,
             payload: %{
               "device_id" => "paired-device",
               "app_version" => "1.0",
               "last_server_seq" => 0,
               "protocol_v" => 2
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
             version: 2,
             type: "hello",
             seq: 1,
             payload: %{
               "device_id" => "paired-device",
               "app_version" => "1.0",
               "last_server_seq" => 0,
               "protocol_v" => 2
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
        negotiated_version: 2,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, "request" -> {:ok, "request", :noise} end,
        decode_client: fn "request", _opts ->
          {:ok,
           %{
             type: "media_fetch",
             version: 2,
             seq: 1,
             payload: %{"ref" => digest},
             bytes: <<>>
           }}
        end,
        media_descriptor: fn "work", ^digest -> {:ok, descriptor} end,
        encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end
      })

    assert {:ok, state} = SocketHandler.handle_in({"request", opcode: :binary}, state)
    assert state.client_seq == 1

    assert {:push, {:binary, begin_frame}, state} = media_step(state)
    assert {:push, {:binary, chunk_frame}, state} = media_step(state)
    assert {:push, {:binary, end_frame}, next} = media_step(state)
    refute_received :mobile_media_step

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

  test "a media frame that fails to encode never advances the Noise send cipher" do
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
        negotiated_version: 2,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn 0, "request" -> {:ok, "request", 0} end,
        decode_client: fn "request", _opts ->
          {:ok,
           %{
             type: "media_fetch",
             version: 2,
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

    assert {:ok, state} = SocketHandler.handle_in({"request", opcode: :binary}, state)
    assert {:push, {:binary, {0, "media_begin-1"}}, state} = media_step(state)
    assert {:push, {:binary, {1, "media_chunk-2"}}, state} = media_step(state)

    # media_end cannot be encoded: the typed error takes the very next nonce.
    assert {:push, {:binary, {2, "error-3"}}, next} = media_step(state)
    assert next.noise == 3
    assert next.server_seq == 3
    assert next.media_transfer == nil
    refute_received :mobile_media_step
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
             version: 2,
             seq: 1,
             payload: %{"ref" => digest},
             bytes: <<>>
           }}
        end,
        media_descriptor: fn "main", ^digest -> {:ok, descriptor} end,
        encode_server: fn "error", payload, 1 ->
          assert payload["code"] == "media_gone"
          assert payload["ref"] == digest
          {:ok, "gone"}
        end,
        encrypt: fn :noise, "gone" -> {:ok, "encrypted-gone", :noise} end
      })

    assert {:ok, state} = SocketHandler.handle_in({"request", opcode: :binary}, state)
    assert state.client_seq == 1

    assert {:push, {:binary, "encrypted-gone"}, next} = media_step(state)
    assert next.server_seq == 1
    refute_received :mobile_media_step
  end

  test "a blob streams one chunk per step so inbound frames are read in between" do
    {store, digest, bytes} = stored_blob("socket-media-stream", 61_441)
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(
        media_fetch_state(store, digest, bytes, %{
          event_router: fn event, _context, _opts ->
            send(test_pid, {:routed, event.type})
            :ok
          end
        })
      )

    assert {:ok, state} =
             SocketHandler.handle_in({fetch_frame(digest, 1), opcode: :binary}, state)

    assert {:push, {:binary, begin_frame}, state} = media_step(state)
    assert {%{"t" => "media_begin"}, <<>>} = decode_server_frame(begin_frame)

    # A ping lands mid-transfer and is answered before the next chunk goes out.
    assert {:ok, state} = SocketHandler.handle_in({ping_frame(2), opcode: :binary}, state)
    assert_received {:routed, "ping"}

    assert {:push, {:binary, first}, state} = media_step(state)
    assert {:push, {:binary, second}, state} = media_step(state)
    assert {:push, {:binary, end_frame}, next} = media_step(state)
    refute_received :mobile_media_step

    assert {%{"t" => "media_chunk", "index" => 0}, head} = decode_server_frame(first)
    assert {%{"t" => "media_chunk", "index" => 1}, tail} = decode_server_frame(second)
    assert head <> tail == bytes
    assert {%{"t" => "media_end", "sha256" => ^digest}, <<>>} = decode_server_frame(end_frame)
    assert next.server_seq == 4
    assert next.client_seq == 2
  end

  test "a fetch that arrives mid-transfer waits for the current blob to finish" do
    {store, first_digest, first_bytes} = stored_blob("socket-media-queue", 3)
    assert {:ok, second_digest} = MediaStore.put_bytes(store, "second")

    descriptors = %{
      first_digest => media_descriptor(first_digest, first_bytes),
      second_digest => media_descriptor(second_digest, "second")
    }

    {:ok, state} =
      SocketHandler.init(
        media_fetch_state(store, first_digest, first_bytes, %{
          media_descriptor: fn "main", ref -> Map.fetch(descriptors, ref) end
        })
      )

    assert {:ok, state} =
             SocketHandler.handle_in({fetch_frame(first_digest, 1), opcode: :binary}, state)

    assert {:push, {:binary, _begin}, state} = media_step(state)

    assert {:ok, state} =
             SocketHandler.handle_in({fetch_frame(second_digest, 2), opcode: :binary}, state)

    frames = drain_media(state, [], 16)
    refute_received :mobile_media_step

    assert Enum.map(frames, &{&1["t"], &1["ref"]}) == [
             {"media_chunk", first_digest},
             {"media_end", first_digest},
             {"media_begin", second_digest},
             {"media_chunk", second_digest},
             {"media_end", second_digest}
           ]
  end

  # D1(c): the refusal can arrive between another blob's chunks, so it names
  # the fetch it refuses, as every other media error does.
  test "a media fetch backlog is refused loudly instead of growing without bound" do
    {store, digest, bytes} = stored_blob("socket-media-backlog", 3)

    {:ok, state} =
      SocketHandler.init(
        media_fetch_state(store, digest, bytes, %{
          encode_server: fn "error", payload, 1 ->
            assert payload["code"] == "media_fetch_backlog_full"
            assert payload["ref"] == digest
            {:ok, "backlog"}
          end
        })
      )

    state =
      Enum.reduce(1..8, state, fn seq, state ->
        assert {:ok, next} =
                 SocketHandler.handle_in({fetch_frame(digest, seq), opcode: :binary}, state)

        next
      end)

    assert {:push, {:binary, "backlog"}, next} =
             SocketHandler.handle_in({fetch_frame(digest, 9), opcode: :binary}, state)

    assert length(next.media_queue) == 8
  end

  test "a digest mismatch found while streaming ends the transfer with a typed error" do
    {store, digest, bytes} = stored_blob("socket-media-mismatch", 3)
    assert {:ok, blob} = MediaStore.fetch(store, digest)
    File.write!(blob.path, "PDF")

    {:ok, state} = SocketHandler.init(media_fetch_state(store, digest, bytes, %{}))

    assert {:ok, state} =
             SocketHandler.handle_in({fetch_frame(digest, 1), opcode: :binary}, state)

    assert {:push, {:binary, _begin}, state} = media_step(state)
    assert {:push, {:binary, _chunk}, state} = media_step(state)
    assert {:push, {:binary, error_frame}, next} = media_step(state)

    assert {%{"t" => "error", "code" => "media_descriptor_mismatch", "ref" => ^digest}, <<>>} =
             decode_server_frame(error_frame)

    assert next.media_transfer == nil
  end

  test "a transfer cut short by the socket closing releases its open blob" do
    {store, digest, bytes} = stored_blob("socket-media-close", 3)
    {:ok, state} = SocketHandler.init(media_fetch_state(store, digest, bytes, %{}))

    assert {:ok, state} =
             SocketHandler.handle_in({fetch_frame(digest, 1), opcode: :binary}, state)

    assert {:push, {:binary, _begin}, state} = media_step(state)
    assert %{io: io} = state.media_transfer
    assert {:ok, _chunk} = :file.read(io, 1)

    # No registered device here: only the transfer's own cleanup is under test.
    assert :ok = SocketHandler.terminate(:normal, %{state | device_id: nil})
    assert {:error, :einval} = :file.read(io, 1)
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
             version: 2,
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
             version: 2,
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
        negotiated_version: 2,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn
          "first", _opts -> {:ok, %{type: "ping", version: 2, seq: 1, payload: %{}, bytes: <<>>}}
          "second", _opts -> {:ok, %{type: "ping", version: 2, seq: 2, payload: %{}, bytes: <<>>}}
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
        negotiated_version: 2,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn
          "msg", _opts -> {:ok, client_msg("c1", 1)}
          "ping", _opts -> {:ok, %{type: "ping", version: 2, seq: 2, payload: %{}, bytes: <<>>}}
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
        negotiated_version: 2,
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

  # After `accepted` the app has dropped the request from its outbox, so its
  # failure must say which request it ends, and reach the device wherever it is
  # connected now, never only the socket that sent it.
  test "an asynchronous request failure reaches the device, correlated to its request" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 2,
        device_registry: :registry,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, "msg" -> {:ok, "msg", :noise} end,
        decode_client: fn "msg", _opts -> {:ok, client_msg("c1", 1)} end,
        event_router: fn _event, _context, _opts -> {:error, :busy} end,
        run_request: fn job -> {:ok, spawn(job)} end,
        send_device_event: fn :registry, device_id, event ->
          send(test_pid, {:device_event, device_id, event})
          :ok
        end
      })

    assert {:ok, _state} = SocketHandler.handle_in({"msg", opcode: :binary}, state)

    assert_receive {:device_event, "paired-device",
                    %{
                      "t" => "error",
                      "code" => "busy",
                      "message" => ":busy",
                      "client_msg_id" => "c1"
                    }}
  end

  test "a request's failure reaches the socket that replaced the one that sent it" do
    test_pid = self()

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: :"replaced_registry_#{System.unique_integer([:positive])}",
         authorize_device: fn _store, id -> {:ok, %{device_id: id}} end}
      )

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 2,
        device_registry: registry,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, "msg" -> {:ok, "msg", :noise} end,
        decode_client: fn "msg", _opts -> {:ok, client_msg("c9", 1)} end,
        event_router: fn _event, _context, _opts ->
          send(test_pid, {:routing, self()})
          receive(do: (:fail -> {:error, {:attachment_unavailable, "photo", :evicted}}))
        end,
        run_request: fn job -> {:ok, spawn(job)} end
      })

    assert :ok = DeviceRegistry.attach(registry, "paired-device", self())
    assert {:ok, _state} = SocketHandler.handle_in({"msg", opcode: :binary}, state)
    assert_receive {:routing, worker}

    replacement = spawn_link(fn -> forward_to(test_pid) end)
    assert :ok = DeviceRegistry.attach(registry, "paired-device", replacement)
    assert_receive {:mobile_replaced, ^replacement}

    send(worker, :fail)

    assert_receive {:forwarded,
                    {:mobile_event,
                     %{
                       "t" => "error",
                       "code" => "attachment_unavailable",
                       "client_msg_id" => "c9"
                     }}}

    refute_received {:mobile_event, _event}
  end

  test "a worker that dies reports a bounded typed error and starts the next request" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 2,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn <<seq>>, _opts -> {:ok, client_msg("c#{seq}", seq)} end,
        event_router: fn _event, _context, _opts -> :ok end,
        run_request: fn job ->
          pid = spawn(fn -> receive(do: (:run -> job.())) end)
          send(test_pid, {:launched, pid})
          {:ok, pid}
        end,
        encode_server: fn "error", payload, 1, <<>>, 2 ->
          assert payload["code"] == "request_failed"
          assert payload["client_msg_id"] == "c1"
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
        negotiated_version: 2,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ciphertext -> {:ok, ciphertext, :noise} end,
        decode_client: fn <<seq>>, _opts -> {:ok, client_msg("c#{seq}", seq)} end,
        event_router: fn _event, _context, _opts -> :ok end,
        run_request: fn _job -> {:ok, worker} end,
        encode_server: fn "error", payload, 1, <<>>, 2 ->
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
             version: 2,
             seq: 2,
             payload: %{
               "device_id" => "paired-device",
               "app_version" => "1.0",
               "last_server_seq" => 0,
               "protocol_v" => 2
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

  # A reconnecting phone asks how its requests stand before it drains its
  # outbox: a known event, answered by the router, never the terminal refusal.
  test "a request_status on a paired socket reaches the router and the session stays up" do
    test_pid = self()
    status = encode_client_frame("request_status", %{"client_msg_ids" => ["c1", "c2"]}, 1)

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, ^status -> {:ok, status, :noise} end,
        event_router: fn event, context, _opts ->
          send(test_pid, {:routed, event.type, event.payload, context})
          :ok
        end
      })

    assert {:ok, next} = SocketHandler.handle_in({status, opcode: :binary}, state)

    assert_received {:routed, "request_status", %{"client_msg_ids" => ["c1", "c2"]},
                     %{transport: :mobile, authenticated_device_id: "paired-device"}}

    assert next.client_seq == 1
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

  # D1(b): the unknown name is the peer's own text, up to the 4 KiB header.
  test "the unsupported refusal's message is bounded like every other error" do
    unknown = encode_client_frame(String.duplicate("x", 4_000), %{}, 1)
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        decrypt: fn :noise, ^unknown -> {:ok, unknown, :noise} end,
        encode_server: fn "error", payload, 1 ->
          send(test_pid, {:refusal, payload})
          {:ok, "typed-error"}
        end,
        encrypt: fn :noise, "typed-error" -> {:ok, "encrypted-error", :noise} end
      })

    assert {:stop, {:unknown_event, _type}, {1002, "mobile protocol error"}, _frames, _next} =
             SocketHandler.handle_in({unknown, opcode: :binary}, state)

    assert_received {:refusal, %{"code" => "unsupported", "message" => message}}
    assert byte_size(message) <= 512
  end

  # D1(d): a refusal the phone can act on reaches it as its own code; only a
  # failure no client can do anything about is request_failed.
  test "a typed refusal reaches the phone as its own code, any other as request_failed" do
    cases = [
      {{:store_quota_exceeded, 5}, "store_quota_exceeded"},
      {{:media_too_large, 5, 4}, "media_too_large"},
      {{:sha256_mismatch, expected: "a", actual: "b"}, "sha256_mismatch"},
      {{:announced_hash_mismatch, "a", "b"}, "announced_hash_mismatch"},
      {{:size_mismatch, 4, 3}, "size_mismatch"},
      {{:size_exceeded, 5, 4}, "size_exceeded"},
      {{:unexpected_chunk, expected: 1, got: 2}, "unexpected_chunk"},
      {{:invalid_field, :sha256}, "invalid_field"},
      {{:missing_field, "profile_id"}, "missing_field"},
      {{:attachment_unavailable, "attach-1", :enoent}, "attachment_unavailable"},
      {{:unsupported_event, "pair_request"}, "unsupported_event"},
      {{:push_environment_mismatch, :production, "development"}, "push_environment_mismatch"},
      {{:manifest_write_failed, :enospc}, "request_failed"},
      {{:request_failed, :killed}, "request_failed"}
    ]

    for {reason, code} <- cases do
      assert refusal_code(reason) == code, "#{inspect(reason)} did not reach the phone as #{code}"
    end
  end

  test "an upload over the store's quota, or empty with another digest, is refused by name" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("socket-upload-refusals")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

    store =
      start_supervised!(
        {MediaStore, name: nil, root: root, max_media_bytes: 4, max_store_bytes: 6}
      )

    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        media_store: store,
        max_media_bytes: 4,
        noise: :noise,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end,
        encode_server: fn type, payload, _seq ->
          send(test_pid, {:sent, type, payload})
          {:ok, type}
        end,
        encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end
      })

    frames = [
      attach_begin_frame("first", 4, 1),
      attach_begin_frame("second", 4, 2),
      attach_begin_frame("empty", 0, 3)
    ]

    Enum.reduce(frames, state, fn frame, state ->
      assert {:push, _frames, next} = SocketHandler.handle_in({frame, opcode: :binary}, state)
      next
    end)

    assert_received {:sent, "attach_status", %{"attach_id" => "first"}}
    assert_received {:sent, "error", %{"code" => "store_quota_exceeded"}}
    assert_received {:sent, "error", %{"code" => "sha256_mismatch"}}
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
          "first", _opts -> {:ok, %{type: "ping", version: 2, seq: 1, payload: %{}, bytes: <<>>}}
          "second", _opts -> {:ok, %{type: "ping", version: 3, seq: 2, payload: %{}, bytes: <<>>}}
        end,
        event_router: fn _event, _context, _opts -> :ok end
      })

    assert {:ok, state} = SocketHandler.handle_in({"first", opcode: :binary}, state)
    assert state.negotiated_version == 2

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
        negotiated_version: 2,
        client_seq: 1,
        decrypt: fn :noise, "ping" -> {:ok, "ping", :noise1} end,
        decode_client: fn "ping", _opts ->
          {:ok, %{type: "ping", version: 2, seq: 2, payload: %{}, bytes: <<>>}}
        end,
        encode_server: fn "pong", %{}, 1, <<>>, 2 -> {:ok, "pong-frame"} end,
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
        negotiated_version: 2,
        client_seq: 1,
        decrypt: fn :noise, "early" -> {:ok, "early", :noise1} end,
        decode_client: fn "early", _opts ->
          {:ok,
           %{
             type: "msg",
             version: 2,
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
          {:ok, %{type: "ping", version: 2, seq: 1, payload: %{}, bytes: <<>>}}
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

  test "a fan-out event the codec cannot encode is dropped and the session stays up" do
    test_pid = self()
    handler_id = "socket-drop-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fermix, :channel, :render],
        fn _event, measurements, metadata, _config ->
          # Pinned to this test's process: the socket encodes in the caller.
          if self() == test_pid, do: send(test_pid, {:render, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    state = %{
      phase: :ready,
      device_id: "device",
      noise: 0,
      server_seq: 4,
      negotiated_version: 2,
      encode_server: fn "notice", _payload, 5, <<>>, 2 -> {:error, :encoder_unavailable} end,
      encrypt: fn nonce, plaintext -> {:ok, {nonce, plaintext}, nonce + 1} end
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        event = %{"t" => "notice", "kind" => "info", "text" => "done"}
        assert {:ok, next} = SocketHandler.handle_info({:mobile_event, event}, state)
        send(test_pid, {:next, next})
      end)

    assert_received {:next, next}
    assert next.noise == 0
    assert next.server_seq == 4
    assert log =~ "dropped a notice event"

    assert_received {:render, %{duration_us: duration_us},
                     %{channel: :mobile, status: :encoder_unavailable}}

    assert is_integer(duration_us) and duration_us >= 0
  end

  test "a fan-out event over the header cap goes out as one event_part run" do
    text = String.duplicate("a", 5_000)
    event = %{"t" => "text_done", "turn_id" => "turn-1", "server_seq" => 7, "text" => text}

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "device",
        noise: 0,
        server_seq: 4,
        negotiated_version: 2,
        encrypt: fn nonce, plaintext -> {:ok, plaintext, nonce + 1} end
      })

    assert {:push, [{:binary, first}, {:binary, second}], next} =
             SocketHandler.handle_info({:mobile_event, event}, state)

    assert {%{"t" => "event_part", "seq" => 5, "index" => 0, "count" => 2}, head} =
             decode_server_frame(first)

    assert {%{"t" => "event_part", "seq" => 6, "index" => 1, "count" => 2}, tail} =
             decode_server_frame(second)

    assert Jason.decode!(head <> tail) == event
    assert next.server_seq == 6
    assert next.noise == 2
  end

  test "a part that cannot be encrypted closes the session: the send nonce already moved" do
    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "device",
        noise: 0,
        negotiated_version: 2,
        encrypt: fn
          0, plaintext -> {:ok, plaintext, 1}
          1, _plaintext -> {:error, :nonce_exhausted}
        end
      })

    event = %{"t" => "notice", "kind" => "info", "text" => String.duplicate("a", 5_000)}

    assert {:stop, :nonce_exhausted, {1002, "mobile protocol error"}, _state} =
             SocketHandler.handle_info({:mobile_event, event}, state)
  end

  # R3-1: the transport bounds the connection from accept to the upgrade; the
  # socket's own handshake deadline takes over in the same process.
  test "the upgraded socket ends its connection's upgrade deadline" do
    :ok = TlsTransport.start_upgrade_deadline(60_000)
    assert is_integer(TlsTransport.upgrade_deadline())

    assert {:ok, _state} = SocketHandler.init(device_registry: :registry)

    assert TlsTransport.upgrade_deadline() == nil
  end

  test "a socket that has not finished its handshake and hello in 10 s is closed" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        device_registry: :registry,
        schedule_handshake_deadline: fn message, 10_000 ->
          send(test_pid, {:deadline_armed, message})
          make_ref()
        end
      })

    assert_received {:deadline_armed, deadline}

    for phase <- [:prelude, :await_hello] do
      assert {:stop, :handshake_timeout, {1008, "mobile handshake deadline"}, _state} =
               SocketHandler.handle_info(deadline, %{state | phase: phase})
    end

    # A request waiting for the owner is bounded by its window's TTL, which
    # tells the socket when it closes; a ready socket said hello in time.
    for phase <- [:await_pair_decision, :ready] do
      assert {:ok, _state} = SocketHandler.handle_info(deadline, %{state | phase: phase})
    end
  end

  # R1-1: a peer holding the gateway key (it is in every pairing QR) finished
  # the first Noise message and then sent nothing, while pings kept the
  # transport's idle timer alive: the socket held a connection slot until the
  # one-hour session timer.
  test "a pairing socket that never sends its pair request is closed and counted" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        pair_manager: :pair,
        schedule_handshake_deadline: fn message, 10_000 ->
          send(test_pid, {:deadline_armed, message})
          make_ref()
        end,
        record_pair_failure: fn :pair, "pair-session" ->
          send(test_pid, :failure_recorded)
          {:ok, 1}
        end
      })

    assert_received {:deadline_armed, deadline}
    parked = Map.merge(state, %{phase: :await_pair_request, pairing_session_id: "pair-session"})

    assert {:stop, :handshake_timeout, {1008, "mobile handshake deadline"}, stopped} =
             SocketHandler.handle_info(deadline, parked)

    assert_received :failure_recorded
    assert :ok = SocketHandler.terminate(:handshake_timeout, stopped)
    refute_received :failure_recorded
  end

  # R1-8: the owner approved at 7 s and the app asked for notification
  # permission before its hello at 12 s; the deadline armed at the upgrade
  # closed the freshly paired socket at 10 s.
  test "a phone the owner approved gets a fresh deadline for its hello" do
    test_pid = self()

    request = %{
      type: "pair_request",
      version: 2,
      seq: 1,
      payload: %{
        "device_name" => "Phone",
        "model" => "iPhone17,1",
        "app_version" => "1.0",
        "platform" => "ios",
        "attestation" => %{"kind" => "apple_app_attest", "cert_lengths" => [5]}
      },
      bytes: "chain"
    }

    {:ok, state} =
      SocketHandler.init(%{
        pair_manager: :pair,
        noise: :noise,
        schedule_handshake_deadline: fn message, 10_000 ->
          timer = make_ref()
          send(test_pid, {:deadline_armed, message, timer})
          timer
        end,
        cancel_handshake_deadline: fn timer ->
          send(test_pid, {:deadline_cancelled, timer})
          false
        end,
        decrypt: fn :noise, "request" -> {:ok, "request", :noise} end,
        decode_client: fn "request", _opts -> {:ok, request} end,
        submit_pair: fn :pair, "pair-session", %{platform: "ios"} -> {:ok, %{}} end,
        discover: fn -> {:ok, []} end,
        encode_server: fn "pair_approved", _payload, 1 -> {:ok, "approved"} end,
        encrypt: fn :noise, "approved" -> {:ok, "encrypted-approved", :noise} end
      })

    assert_received {:deadline_armed, upgrade_deadline, upgrade_timer}

    parked =
      Map.merge(state, %{
        phase: :await_pair_request,
        pairing_session_id: "pair-session",
        pairing_remote_static: <<4::256>>,
        pairing_sas: "047291"
      })

    assert {:ok, deciding} = SocketHandler.handle_in({"request", opcode: :binary}, parked)
    assert deciding.phase == :await_pair_decision
    assert_received {:deadline_cancelled, ^upgrade_timer}

    device = %{device_id: "new-device", apns_key_salt: <<9::256>>}
    decision = {:mobile_pair_decision, "pair-session", {:ok, device}}

    assert {:push, {:binary, "encrypted-approved"}, approved} =
             SocketHandler.handle_info(decision, deciding)

    assert approved.phase == :await_hello
    assert_received {:deadline_armed, hello_deadline, _hello_timer}
    refute hello_deadline == upgrade_deadline

    assert {:ok, ^approved} = SocketHandler.handle_info(upgrade_deadline, approved)

    assert {:stop, :handshake_timeout, {1008, "mobile handshake deadline"}, _state} =
             SocketHandler.handle_info(hello_deadline, approved)
  end

  test "a socket that says hello in time drops its deadline" do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(
        hello_state(%{
          phase: :prelude,
          hello_ack_builder: fn _state -> {:ok, %{"session_id" => "session"}} end,
          encode_server: fn "hello_ack", _payload, 1 -> {:ok, "encoded"} end,
          pending_approvals: fn "main" -> [] end,
          schedule_handshake_deadline: fn message, 10_000 ->
            timer = make_ref()
            send(test_pid, {:deadline_armed, message, timer})
            timer
          end,
          cancel_handshake_deadline: fn timer ->
            send(test_pid, {:deadline_cancelled, timer})
            false
          end
        })
      )

    assert_received {:deadline_armed, deadline, timer}

    assert {:push, {:binary, "ciphertext-out"}, ready} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, %{
               state
               | phase: :await_hello
             })

    assert ready.phase == :ready
    assert_received {:deadline_cancelled, ^timer}
    assert {:ok, ^ready} = SocketHandler.handle_info(deadline, ready)
  end

  test "a socket built past the prelude arms no handshake deadline" do
    test_pid = self()

    {:ok, _state} =
      SocketHandler.init(%{
        phase: :ready,
        schedule_handshake_deadline: fn _message, _ms -> send(test_pid, :deadline_armed) end
      })

    refute_received :deadline_armed
  end

  test "a hello outside the version window gets a typed refusal at the daemon's version" do
    test_pid = self()

    hello =
      client_frame(3, "hello", 1, %{
        "device_id" => "paired-device",
        "app_version" => "9.0",
        "last_server_seq" => 0,
        "protocol_v" => 3
      })

    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_hello,
        authenticated_device: %{device_id: "paired-device"},
        device_registry: :registry,
        noise: :noise,
        decrypt: fn :noise, ^hello -> {:ok, hello, :noise} end,
        encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end,
        attach_socket: fn _registry, _device_id, _pid, _opts ->
          send(test_pid, :attached)
          :ok
        end
      })

    assert {:stop, {:unsupported_protocol_version, :client_too_new},
            {1002, "unsupported mobile protocol version"}, [{:binary, frame}], _next} =
             SocketHandler.handle_in({hello, opcode: :binary}, state)

    assert {%{"v" => 2, "t" => "error", "seq" => 1} = refusal, <<>>} = decode_server_frame(frame)
    assert refusal["code"] == "unsupported_protocol_version"
    assert refusal["direction"] == "client_too_new"
    assert refusal["client_version"] == 3
    assert refusal["min_version"] == 2
    assert refusal["max_version"] == 2
    refute_received :attached
  end

  test "a pair_request outside the version window is refused typed and is no failed pairing" do
    test_pid = self()
    request = client_frame(1, "pair_request", 1, %{"device_name" => "a", "model" => "b"})

    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_pair_request,
        pair_manager: :pair,
        pairing_session_id: "pair-session",
        noise: :noise,
        decrypt: fn :noise, ^request -> {:ok, request, :noise} end,
        encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end,
        submit_pair: fn _pair, _session, _attrs -> send(test_pid, :submitted) end,
        record_pair_failure: fn :pair, "pair-session" ->
          send(test_pid, :failure_recorded)
          {:ok, 1}
        end
      })

    assert {:stop, {:unsupported_protocol_version, :client_too_old} = reason, {1002, _text},
            [{:binary, frame}], stopped} =
             SocketHandler.handle_in({request, opcode: :binary}, state)

    assert {%{"code" => "unsupported_protocol_version", "direction" => "client_too_old"}, <<>>} =
             decode_server_frame(frame)

    assert :ok = SocketHandler.terminate(reason, stopped)
    refute_received :failure_recorded
    refute_received :submitted
  end

  test "hello_ack carries at most 16 candidates, best first" do
    candidates =
      for last <- 1..20, do: %{address: "10.0.0.#{last}", interface: "en0", scope: :lan}

    {:ok, state} =
      SocketHandler.init(
        hello_state(%{
          discover: fn -> {:ok, candidates} end,
          encode_server: fn "hello_ack", payload, 1 ->
            assert length(payload["candidates"]) == 16

            assert hd(payload["candidates"]) == %{
                     "host" => "10.0.0.1",
                     "interface" => "en0",
                     "scope" => "lan"
                   }

            assert List.last(payload["candidates"])["host"] == "10.0.0.16"
            {:ok, "encoded"}
          end
        })
      )

    assert {:push, {:binary, "ciphertext-out"}, _next} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)
  end

  # FEAT-2: a phone that was away when an approval went out gets it right
  # after its hello_ack, in the same push.
  test "an approval still waiting follows the hello_ack" do
    approval = %{
      "t" => "approval",
      "approval_id" => "sandbox-abc",
      "kind" => "sandbox",
      "text" => "Allow?",
      "token" => "TOKEN",
      "ttl_s" => 42,
      "approve_command" => "/confirm TOKEN",
      "deny_command" => "/deny TOKEN"
    }

    {:ok, state} =
      SocketHandler.init(
        hello_state(%{
          discover: fn -> {:ok, []} end,
          pending_approvals: fn "main" -> [approval] end,
          encode_server: fn
            "hello_ack", _payload, 1 -> {:ok, "encoded"}
            "approval", payload, 2 -> {:ok, "approval:" <> payload["approval_id"]}
          end,
          encrypt: fn
            :noise1, "encoded" -> {:ok, "ciphertext-out", :noise2}
            :noise2, "approval:sandbox-abc" -> {:ok, "approval-out", :noise3}
          end
        })
      )

    assert {:push, [{:binary, "ciphertext-out"}, {:binary, "approval-out"}], next} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)

    assert next.server_seq == 2
  end

  test "hello_ack reads candidates from the supervised discovery cache" do
    discovery =
      start_supervised!(
        {Discovery,
         name: nil,
         discover: fn ->
           {:ok, [%{address: "fermix-host.tail1.ts.net", interface: "utun4", scope: :tailnet}]}
         end}
      )

    {:ok, state} =
      SocketHandler.init(
        hello_state(%{
          discovery: discovery,
          encode_server: fn "hello_ack", payload, 1 ->
            assert [%{"host" => "fermix-host.tail1.ts.net"}] = payload["candidates"]
            {:ok, "encoded"}
          end
        })
      )

    assert {:push, {:binary, "ciphertext-out"}, _next} =
             SocketHandler.handle_in({"ciphertext", opcode: :binary}, state)
  end

  test "pair_approved reads the socket's discovery source and caps its candidates" do
    candidates =
      for last <- 1..20, do: %{address: "10.0.0.#{last}", interface: "en0", scope: :lan}

    {:ok, state} =
      SocketHandler.init(%{
        phase: :await_pair_decision,
        pairing_session_id: "pair-session",
        noise: :noise,
        negotiated_version: 2,
        profile_name: "Orbit",
        discover: fn -> {:ok, candidates} end,
        encode_server: fn "pair_approved", payload, 1 ->
          assert length(payload["candidates"]) == 16
          assert payload["push_salt"] == Base.encode64(<<9::256>>)
          {:ok, "approved"}
        end,
        encrypt: fn :noise, "approved" -> {:ok, "encrypted-approved", :noise} end
      })

    device = %{device_id: "new-device", apns_key_salt: <<9::256>>}
    decision = {:mobile_pair_decision, "pair-session", {:ok, device}}

    assert {:push, {:binary, "encrypted-approved"}, next} =
             SocketHandler.handle_info(decision, state)

    assert next.phase == :await_hello
  end

  defp hello_state(overrides) do
    hello = %{
      version: 2,
      type: "hello",
      seq: 1,
      payload: %{
        "device_id" => "paired-device",
        "app_version" => "1.0",
        "last_server_seq" => 0,
        "protocol_v" => 2
      },
      bytes: <<>>
    }

    Map.merge(
      %{
        phase: :await_hello,
        authenticated_device: %{device_id: "paired-device"},
        device_registry: :registry,
        noise: :noise,
        decrypt: fn :noise, "ciphertext" -> {:ok, "plaintext", :noise1} end,
        decode_client: fn "plaintext", _opts -> {:ok, hello} end,
        update_device: fn _store, "paired-device", %{last_seen: %DateTime{}} ->
          {:ok, %{device_id: "paired-device"}}
        end,
        attach_socket: fn :registry, "paired-device", _pid, profile_id: "main" -> :ok end,
        history_head: fn "main" -> {:ok, 0} end,
        read_frontier: fn "main" -> {:ok, 0} end,
        encrypt: fn :noise1, "encoded" -> {:ok, "ciphertext-out", :noise2} end
      },
      overrides
    )
  end

  defp media_step(state) do
    assert_received :mobile_media_step
    SocketHandler.handle_info(:mobile_media_step, state)
  end

  defp drain_media(_state, _frames, 0), do: flunk("the media transfer never settled")

  defp drain_media(state, frames, remaining) do
    receive do
      :mobile_media_step ->
        assert {:push, {:binary, frame}, state} =
                 SocketHandler.handle_info(:mobile_media_step, state)

        {header, _bytes} = decode_server_frame(frame)
        drain_media(state, [header | frames], remaining - 1)
    after
      0 -> Enum.reverse(frames)
    end
  end

  defp stored_blob(prefix, size) do
    root = FermixTestSupport.SafeRm.make_tmp_dir!(prefix)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    store = start_supervised!({MediaStore, name: nil, root: root, max_store_bytes: 1_000_000})
    bytes = for index <- 1..size, into: <<>>, do: <<rem(index, 251)>>
    assert {:ok, digest} = MediaStore.put_bytes(store, bytes)
    {store, digest, bytes}
  end

  defp media_descriptor(digest, bytes) do
    %{
      server_seq: 41,
      media: %{
        "ref" => digest,
        "sha256" => digest,
        "kind" => "document",
        "mime" => "application/octet-stream",
        "size_bytes" => byte_size(bytes)
      }
    }
  end

  defp media_fetch_state(store, digest, bytes, overrides) do
    Map.merge(
      %{
        phase: :ready,
        device_id: "paired-device",
        profile_id: "main",
        media_store: store,
        noise: :noise,
        negotiated_version: 2,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, frame -> {:ok, frame, :noise} end,
        encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end,
        media_descriptor: fn "main", ^digest -> {:ok, media_descriptor(digest, bytes)} end
      },
      overrides
    )
  end

  defp fetch_frame(ref, seq), do: encode_client_frame("media_fetch", %{"ref" => ref}, seq)
  defp ping_frame(seq), do: encode_client_frame("ping", %{}, seq)

  defp client_frame(version, type, seq, payload) do
    header = payload |> Map.merge(%{"v" => version, "t" => type, "seq" => seq}) |> Jason.encode!()
    <<byte_size(header)::unsigned-big-32, header::binary>>
  end

  defp forward_to(test_pid) do
    receive do
      message -> send(test_pid, {:forwarded, message})
    end

    forward_to(test_pid)
  end

  defp client_msg(client_msg_id, seq) do
    %{
      type: "msg",
      version: 2,
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

  defp attach_begin_frame(attach_id, size_bytes, seq \\ 1) do
    payload = %{
      "attach_id" => attach_id,
      "kind" => "document",
      "mime" => "application/pdf",
      "size_bytes" => size_bytes,
      "sha256" => String.duplicate("a", 64)
    }

    encode_client_frame("attach_begin", payload, seq)
  end

  # The code a ready socket sends for an event its router refuses with `reason`.
  defp refusal_code(reason) do
    test_pid = self()

    {:ok, state} =
      SocketHandler.init(%{
        phase: :ready,
        device_id: "paired-device",
        noise: :noise,
        negotiated_version: 2,
        authorize_socket: fn _registry, "paired-device", _pid -> :ok end,
        decrypt: fn :noise, frame -> {:ok, frame, :noise} end,
        event_router: fn _event, _context, _opts -> {:error, reason} end,
        encode_server: fn "error", payload, 1 ->
          send(test_pid, {:refusal_code, payload["code"]})
          {:ok, "error-frame"}
        end,
        encrypt: fn :noise, "error-frame" -> {:ok, "encrypted-error", :noise} end
      })

    assert {:push, {:binary, "encrypted-error"}, _next} =
             SocketHandler.handle_in({ping_frame(1), opcode: :binary}, state)

    assert_received {:refusal_code, code}
    code
  end

  defp encode_client_frame(type, payload, seq) do
    header = payload |> Map.merge(%{"v" => 2, "t" => type, "seq" => seq}) |> Jason.encode!()
    <<byte_size(header)::unsigned-big-32, header::binary>>
  end

  defp decode_server_frame(<<header_size::unsigned-big-32, rest::binary>>) do
    <<header::binary-size(header_size), bytes::binary>> = rest
    {Jason.decode!(header), bytes}
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
