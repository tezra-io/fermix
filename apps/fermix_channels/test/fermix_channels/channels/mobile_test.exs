defmodule FermixChannels.Channels.MobileTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Gateway.Commands.Registry, as: CommandRegistry
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Mobile.MediaStore

  defmodule StoreStub do
    def append(profile_id, attrs, _opts) do
      send(self(), {:timeline_append, profile_id, attrs})
      row = Map.merge(attrs, %{profile_id: profile_id, server_seq: 73})
      Process.put({__MODULE__, :last_row}, row)
      {:ok, row}
    end

    def append_client_output(profile, client_id, attempt, key, attrs, _opts) do
      send(self(), {:fenced_output, profile, client_id, attempt, key})
      append(profile, Map.put(attrs, :role, "assistant"), [])
      |> then(fn {:ok, row} -> {:ok, {:created, row}} end)
    end

    def append_client_response(profile, client_id, attempt, attrs, _opts) do
      send(self(), {:fenced_response, profile, client_id, attempt})

      append(profile, Map.put(attrs, :role, "assistant"), [])
      |> then(fn {:ok, row} -> {:ok, {:created, row}} end)
    end

    def append_proactive(profile, key, attrs, _opts) do
      seen = Process.get({__MODULE__, :proactive}, MapSet.new())

      if MapSet.member?(seen, key) do
        {:ok, {:existing, Process.get({__MODULE__, {:proactive_row, key}})}}
      else
        {:ok, row} = append(profile, attrs, [])
        Process.put({__MODULE__, :proactive}, MapSet.put(seen, key))
        Process.put({__MODULE__, {:proactive_row, key}}, row)
        {:ok, {:created, row}}
      end
    end

    def complete_client_request(profile, client_id, attempt, fields, _opts) do
      send(self(), {:request_completed, profile, client_id, attempt, fields})
      {:ok, %{status: "completed", attempt: attempt, result_server_seq: 73}}
    end

    def fail_client_request(profile, client_id, attempt, fields, _opts) do
      send(self(), {:request_failed, profile, client_id, attempt, fields})
      {:ok, %{status: "failed", attempt: attempt, result_server_seq: 73}}
    end

    def history_page(_profile, _opts) do
      {:ok, %{messages: [Process.get({__MODULE__, :last_row})], next_after_seq: nil}}
    end

    def attach_timeline_media(profile, server_seq, descriptor, _opts) do
      send(self(), {:thumbnail_attached, profile, server_seq, descriptor})
      {:ok, %{server_seq: server_seq, media_refs: [descriptor]}}
    end
  end

  defmodule HealthyManagement do
    def health, do: {:ok, %{listener: :ready, identity: :ready, paired_devices: 2}}
  end

  defmodule DownManagement do
    def health, do: {:error, {:listener_unavailable, :down}}
  end

  setup do
    test_pid = self()
    previous = Application.fetch_env(:fermix_channels, :mobile_event_sink)
    previous_store = Application.fetch_env(:fermix_channels, :mobile_store)
    previous_media = Application.fetch_env(:fermix_channels, :mobile_media_resolver)
    previous_push = Application.fetch_env(:fermix_channels, :mobile_push)
    previous_push_launcher = Application.fetch_env(:fermix_channels, :mobile_push_launcher)
    previous_unfurl = Application.fetch_env(:fermix_channels, :mobile_unfurl)

    previous_unfurl_launcher =
      Application.fetch_env(:fermix_channels, :mobile_unfurl_launcher)

    Application.put_env(:fermix_channels, :mobile_event_sink, fn profile_id, event ->
      send(test_pid, {:mobile_event, profile_id, event})
      :ok
    end)

    Application.put_env(:fermix_channels, :mobile_store, StoreStub)

    Application.put_env(:fermix_channels, :mobile_media_resolver, fn media ->
      {:ok,
       %{
         "ref" => "sha256:image",
         "kind" => Atom.to_string(media.kind),
         "mime" => media.mime_type,
         "size_bytes" => 5,
         "sha256" => String.duplicate("a", 64),
         "path" => media.path
       }}
    end)

    Application.put_env(:fermix_channels, :mobile_push, fn profile_id, server_seq, preview ->
      send(test_pid, {:push_notify, profile_id, server_seq, preview})
      {:ok, %{status: :sent, sent: 1}}
    end)

    Application.put_env(:fermix_channels, :mobile_push_launcher, fn task ->
      task.()
      :ok
    end)

    Application.put_env(:fermix_channels, :mobile_unfurl, fn text ->
      send(test_pid, {:unfurl_resolve, text})

      {:ok,
       [
         %{
           url: "https://example.com",
           site: "Example",
           title: "Example title",
           description: "Description",
           image_ref: nil
         }
       ], []}
    end)

    Application.put_env(:fermix_channels, :mobile_unfurl_launcher, fn task ->
      task.()
      :ok
    end)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :mobile_event_sink, value)
        :error -> Application.delete_env(:fermix_channels, :mobile_event_sink)
      end

      case previous_store do
        {:ok, value} -> Application.put_env(:fermix_channels, :mobile_store, value)
        :error -> Application.delete_env(:fermix_channels, :mobile_store)
      end

      case previous_media do
        {:ok, value} -> Application.put_env(:fermix_channels, :mobile_media_resolver, value)
        :error -> Application.delete_env(:fermix_channels, :mobile_media_resolver)
      end

      restore_env(:mobile_push, previous_push)
      restore_env(:mobile_push_launcher, previous_push_launcher)
      restore_env(:mobile_unfurl, previous_unfurl)
      restore_env(:mobile_unfurl_launcher, previous_unfurl_launcher)
    end)

    :ok
  end

  describe "parse_event/1" do
    test "normalizes a message onto the shared main profile conversation" do
      event = %{
        type: "msg",
        payload: %{
          "client_msg_id" => "client-1",
          "profile_id" => "main",
          "text" => "hello",
          "attach_ids" => []
        }
      }

      assert {:ok, [%Message{} = message]} = Mobile.parse_event(event)
      assert message.id == "client-1"
      assert message.content == "hello"
      assert message.channel == "mobile"
      assert message.chat_id == "main"
      assert message.reply_target == "main"
      assert message.thread_scope == :root
      assert message.metadata.client_msg_id == "client-1"
      refute Map.has_key?(message.metadata, :transport_auth)
    end

    test "normalizes a command through the ordinary slash-command pipeline" do
      event = %{
        type: "command",
        payload: %{
          "client_msg_id" => "client-2",
          "profile_id" => "main",
          "name" => "sandbox",
          "args" => "status"
        }
      }

      assert {:ok, [%Message{content: "/sandbox status", chat_id: "main"}]} =
               Mobile.parse_event(event)
    end

    test "rejects unsupported profiles and malformed commands" do
      assert {:error, :unsupported_profile} =
               Mobile.parse_event(%{
                 type: "msg",
                 payload: %{
                   "client_msg_id" => "c",
                   "profile_id" => "other",
                   "text" => "x",
                   "attach_ids" => []
                 }
               })

      assert {:error, :invalid_command} =
               Mobile.parse_event(%{
                 type: "command",
                 payload: %{
                   "client_msg_id" => "c",
                   "profile_id" => "main",
                   "name" => "bad name"
                 }
               })
    end
  end

  test "command catalog is generated from the live command registry" do
    assert Mobile.command_catalog() ==
             Enum.map(CommandRegistry.list(), fn command ->
               %{
                 "name" => command.name(),
                 "aliases" => command.aliases(),
                 "description" => command.description()
               }
             end)
  end

  test "draft, activity, terminal, reaction, approval, text, and media callbacks fan out by profile" do
    message = mobile_message()

    assert Mobile.stream_capability() == :draft_edit
    assert {:ok, handle} = Mobile.open_draft(message, "draft")
    turn_id = handle.turn_id
    assert_receive {:mobile_event, "main", %{"t" => "turn_started", "turn_id" => ^turn_id}}
    assert_receive {:mobile_event, "main", %{"t" => "text_delta", "text" => "draft"}}

    assert :ok = Mobile.edit_draft(message, handle, "draft grows")
    assert_receive {:mobile_event, "main", %{"t" => "text_delta", "text" => " grows"}}

    assert {:ok, nil} = Mobile.seal_draft(message, handle, "final")
    assert_received {:fenced_response, "main", "client-1", 2}
    assert_received {:timeline_append, "main", %{role: "assistant", content: "final"}}

    assert_receive {:mobile_event, "main",
                    %{"t" => "text_done", "text" => "final", "server_seq" => 73}}

    activity = Mobile.build_activity_callback(message)
    assert :ok = activity.({:tool_start, "shell"})
    assert_receive {:mobile_event, "main", %{"t" => "tool_event", "phase" => "start"}}

    terminal = Mobile.build_turn_result(message)
    assert :ok = terminal.({:failed, :timeout})
    assert_receive {:mobile_event, "main", %{"t" => "turn_error", "code" => "timeout"}}
    refute_receive {:push_notify, "main", 73, "final"}

    assert :ok = Mobile.react(message, "👍")
    assert_receive {:mobile_event, "main", %{"t" => "reaction", "emoji" => "👍"}}

    assert :ok = Mobile.send_approval(message, "Allow access? /confirm TOKEN", "TOKEN")

    assert_receive {:mobile_event, "main",
                    %{
                      "t" => "approval",
                      "token" => "TOKEN",
                      "approve_command" => "/confirm TOKEN",
                      "deny_command" => "/deny TOKEN"
                    }}

    assert :ok =
             Mobile.send_approval(message, %{
               kind: :soul,
               text: "Apply this? /soul apply SOUL",
               token: "SOUL"
             })

    assert_receive {:mobile_event, "main",
                    %{
                      "kind" => "soul",
                      "ttl_s" => 300,
                      "approve_command" => "/soul apply SOUL",
                      "deny_command" => "/soul deny SOUL"
                    }}

    assert :ok = Mobile.send_message("main", "see https://example.com", [])

    assert_receive {:mobile_event, "main",
                    %{
                      "t" => "text_done",
                      "text" => "see https://example.com",
                      "server_seq" => 73
                    }}

    assert_receive {:push_notify, "main", 73, "see https://example.com"}
    assert_receive {:unfurl_resolve, "see https://example.com"}

    assert_receive {:mobile_event, "main",
                    %{
                      "t" => "link_preview",
                      "in_reply_to" => 73,
                      "url" => "https://example.com"
                    }}

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-outbound")
    path = Path.join(dir, "image.png")
    File.write!(path, "image")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    media = %{kind: :image, path: path, mime_type: "image/png"}
    assert :ok = Mobile.send_media("main", media, [])

    assert_receive {:timeline_append, "main",
                    %{
                      role: "assistant",
                      kind: "media",
                      media_refs: [
                        %{
                          "ref" => "sha256:image",
                          "kind" => "image",
                          "mime" => "image/png",
                          "size_bytes" => 5
                        }
                      ]
                    }}

    assert_receive {:mobile_event, "main", %{"t" => "media_begin", "kind" => "image"}}
    assert_receive {:mobile_event, "main", %{"t" => "media_chunk", "bytes" => "image"}}
    assert_receive {:mobile_event, "main", %{"t" => "media_end"}}
    assert_receive {:push_notify, "main", 73, "Sent an image"}
  end

  test "download_attachment accepts only an existing transport-resolved temp path" do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-upload")
    path = Path.join(dir, "upload.bin")
    File.write!(path, "bytes")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    assert {:ok, ^path} = Mobile.download_attachment(mobile_message(), %{path: path})

    assert {:error, :attachment_unavailable} =
             Mobile.download_attachment(mobile_message(), %{path: path <> "-missing"})
  end

  test "download_attachment unwraps a verified upload descriptor to a regular path" do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-materialized-upload")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    start_supervised!({MediaStore, root: dir, name: MediaStore})

    bytes = "voice-bytes"
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    spec = %{
      attach_id: "voice-1",
      kind: "audio",
      mime: "audio/mp4",
      size_bytes: byte_size(bytes),
      sha256: digest,
      name: "voice.m4a"
    }

    assert {:ok, :upload} = MediaStore.begin_upload(MediaStore, spec)
    assert :ok = MediaStore.write_chunk(MediaStore, "voice-1", 0, bytes)
    assert {:ok, ^digest} = MediaStore.finish_upload(MediaStore, "voice-1", digest)

    assert {:ok, path} =
             Mobile.download_attachment(mobile_message(), %{file_id: "voice-1", kind: :audio})

    assert is_binary(path)
    assert File.regular?(path)
    assert File.read!(path) == bytes
  end

  test "multiple output parts schedule one push at terminal completion" do
    message = mobile_message()
    opts = [
      turn_id: "turn-client-1",
      in_reply_to: "client-1",
      request_type: "msg",
      attempt: 2
    ]

    assert :ok = Mobile.send_message("main", "first", opts)
    assert :ok = Mobile.send_message("main", "final", opts)
    refute_receive {:push_notify, _, _, _}

    terminal = Mobile.build_turn_result(message)
    assert :ok = terminal.({:completed})
    assert_receive {:push_notify, "main", 73, "final"}
    refute_receive {:push_notify, _, _, _}
  end

  test "proactive text retries persist, fan out, and push exactly once" do
    opts = [proactive_key: "job:run-1"]

    assert :ok = Mobile.send_message("main", "daily", opts)
    assert :ok = Mobile.send_message("main", "daily", opts)

    assert_receive {:timeline_append, "main", %{content: "daily"}}
    refute_receive {:timeline_append, "main", %{content: "daily"}}
    assert_receive {:mobile_event, "main", %{"t" => "text_done", "text" => "daily"}}
    refute_receive {:mobile_event, "main", %{"t" => "text_done", "text" => "daily"}}
    assert_receive {:push_notify, "main", 73, "daily"}
    refute_receive {:push_notify, _, _, _}
  end

  test "proactive media requires an explicit deterministic part id" do
    assert {:error, :proactive_media_key_requires_part_id} =
             Mobile.send_media(
               "main",
               %{kind: :image, path: "/unused", mime_type: "image/png"},
               proactive_key: "job:run-1"
             )
  end

  test "link preview thumbnails are durably profile-authorized before fanout" do
    digest = String.duplicate("b", 64)

    resolver = fn text, store_thumbnail ->
      send(self(), {:thumbnail_resolve, text})
      assert {:ok, ^digest} = store_thumbnail.("png-bytes", "image/png")

      {:ok,
       [
         %{
           url: "https://example.com",
           site: "Example",
           title: "Example title",
           description: nil,
           image_ref: digest
         }
       ], []}
    end

    assert :ok =
             Mobile.schedule_unfurl("main", 73, "https://example.com",
               unfurl: resolver,
               unfurl_launcher: fn task ->
                 task.()
                 :ok
               end,
               thumbnail_store: fn _bytes, _mime -> {:ok, digest} end,
               store: StoreStub,
               event_sink: fn target, event ->
                 send(self(), {:preview_event, target, event})
                 :ok
               end
             )

    assert_received {:thumbnail_attached, "main", 73,
                     %{
                       "ref" => ^digest,
                       "sha256" => ^digest,
                       "kind" => "image",
                       "mime" => "image/png",
                       "size_bytes" => 9
                     }}

    assert_received {:preview_event, {:profile, "main"},
                     %{"t" => "link_preview", "image_ref" => ^digest}}
  end

  test "health delegates to the fail-closed mobile management facade" do
    assert {:ok, %{detail: detail}} = Mobile.health_check(management: HealthyManagement)
    assert detail =~ "listener ready"
    assert detail =~ "identity ready"
    assert detail =~ "2 paired device(s)"

    assert {:error, {:listener_unavailable, :down}} =
             Mobile.health_check(management: DownManagement)
  end

  test "a post-commit push failure is observable and never retries timeline persistence" do
    Application.put_env(:fermix_channels, :mobile_push, fn _profile, _seq, _preview ->
      {:error, :apns_down}
    end)

    Application.put_env(:fermix_channels, :mobile_unfurl, fn _text -> {:ok, [], []} end)

    log =
      capture_log(fn ->
        assert :ok = Mobile.send_message("main", "durable once", [])
      end)

    assert log =~ "mobile post-commit push failed: :apns_down"
    assert_receive {:timeline_append, "main", %{content: "durable once"}}
    refute_receive {:timeline_append, "main", %{content: "durable once"}}
  end

  test "webhook callbacks refuse and reactions accept any emoji" do
    assert {:error, :unsupported_transport} = Mobile.parse_webhook(%{})
    assert {:error, :unsupported_transport} = Mobile.verify_webhook(%Plug.Conn{})
    assert Mobile.reaction_capability() == :any_emoji
  end

  defp mobile_message do
    Message.new!(%{
      id: "client-1",
      content: "hello",
      sender: "iPhone",
      channel: "mobile",
      chat_id: "main",
      reply_target: "main",
      metadata:
        %{client_msg_id: "client-1"}
        |> Map.put(:mobile_attempt, 2)
        |> Map.put(:turn_id, "turn-client-1")
    })
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:fermix_channels, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:fermix_channels, key)
end
