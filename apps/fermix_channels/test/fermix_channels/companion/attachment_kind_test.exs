defmodule FermixChannels.Companion.AttachmentKindTest do
  # A phone declares each attachment's `kind`; the daemon reads it as a hint
  # (`Companion.Requests`). `voice` is a recording the owner made in the app, so
  # it becomes the `:voice` hint a channel-declared voice note carries, and the
  # access gate does not count it as outside content. `audio` (an attached file)
  # stays `:audio` and still counts. Either way the timeline names the media
  # `audio`, so a client that does not know `voice` draws it as before.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.EventRouter
  alias FermixCore.Attachments
  alias FermixCore.Capabilities.UntrustedContent

  defmodule StoreStub do
    def claim_client_request(_profile, _id, _type, _payload, _opts),
      do: {:ok, {:claimed, %{status: "running"}}}

    def append_client_message(profile, client_id, attrs, _opts) do
      send(self(), {:appended, profile, attrs})

      {:ok,
       {:created,
        Map.merge(attrs, %{
          role: "user",
          client_msg_id: client_id,
          server_seq: 12,
          created_at: ~U[2026-09-14 09:00:00Z]
        })}}
    end

    def update_client_message(_profile, _id, _attempt, attrs, _opts),
      do: {:ok, Map.merge(attrs, %{server_seq: 12})}

    def settle_client_request(_profile, _id, status, fields, _opts),
      do: {:ok, Map.merge(fields, %{status: Atom.to_string(status), result_server_seq: nil})}

    def complete_client_request(_profile, id, attempt, _fields, _opts),
      do:
        {:ok, %{client_msg_id: id, status: "completed", attempt: attempt, result_server_seq: nil}}

    def fail_client_request(_profile, id, attempt, _fields, _opts),
      do: {:ok, %{client_msg_id: id, status: "failed", attempt: attempt, result_server_seq: nil}}
  end

  defmodule CoordinatorStub do
    def acquire(_server, _profile, _id, _opts), do: {:ok, {:started, %{attempt: 1}}}
    def handoff(_server, _profile, _id, _attempt, _owner), do: :ok
  end

  defmodule GatewayStub do
    def ingest(messages, opts) do
      send(self(), {:gateway_ingest, messages, opts})
      :ok
    end
  end

  # A phone's recording and an attached audio file, as the media store holds
  # each after its upload: the `kind` is the one the phone declared.
  defmodule MediaStoreStub do
    def attachment(:media, "rec-1"), do: {:ok, audio("rec-1", "voice", "a")}
    def attachment(:media, "file-1"), do: {:ok, audio("file-1", "audio", "b")}
    def attachment(:media, _id), do: {:error, :unknown_attachment}

    defp audio(id, kind, fill) do
      %{
        attach_id: id,
        ref: String.duplicate(fill, 64),
        kind: kind,
        mime_type: "audio/ogg",
        size_bytes: 48_213
      }
    end
  end

  # Stands in for `Companion.Turns`: every request here becomes a turn.
  defmodule TurnsStub do
    use GenServer

    def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:cancel, _profile, _client_id}, _from, state), do: {:reply, :ok, state}

    @impl true
    def handle_cast({:settle_unless_handed_off, _key, _attempt, _settle}, state),
      do: {:noreply, state}
  end

  setup do
    test_pid = self()
    turns = start_supervised!(TurnsStub)

    opts = [
      settlement_owner: turns,
      store: StoreStub,
      coordinator: CoordinatorStub,
      request_coordinator: :coordinator,
      gateway: GatewayStub,
      media_store: MediaStoreStub,
      media_server: :media,
      event_sink: fn _target, _event -> :ok end,
      agent: FermixChannels.Gateway.Queue,
      agent_server: test_pid,
      link_preview_launcher: fn task ->
        task.()
        :ok
      end,
      link_preview_resolver: fn _links, _store_thumbnail, _on_preview -> {:ok, []} end
    ]

    %{opts: opts, context: %{transport: :mobile, authenticated_device_id: "device-1"}}
  end

  # A decoded `msg` event as the session hands it to the router.
  defp send_message(ctx, attach_id) do
    event = %{
      type: "msg",
      seq: 2,
      version: 2,
      bytes: <<>>,
      payload: %{
        "client_msg_id" => "client-#{attach_id}",
        "profile_id" => "main",
        "text" => "",
        "attach_ids" => [attach_id]
      }
    }

    assert :ok = EventRouter.route(event, ctx.context, ctx.opts)
    assert_received {:appended, "main", %{media_refs: [ref]}}
    assert_received {:gateway_ingest, [message], _gateway_opts}
    {message, ref}
  end

  # The struct the gateway's attachment pipeline builds from a declared voice
  # recording once it is transcribed: the hint is copied as declared.
  defp transcribed(%{hint: hint}),
    do: %Attachments{kind: :audio, mime_type: "audio/ogg", hint: hint, status: :transcribed}

  test "a recording the phone declares `voice` is the owner's voice, drawn as audio", ctx do
    {message, ref} = send_message(ctx, "rec-1")

    assert [%{file_id: "rec-1", hint: :voice} = declared] = message.attachments
    assert ref["kind"] == "audio"
    assert UntrustedContent.attachment_sources([transcribed(declared)]) == MapSet.new()
  end

  test "an audio file the phone declares `audio` still counts as outside content", ctx do
    {message, ref} = send_message(ctx, "file-1")

    assert [%{file_id: "file-1", hint: :audio} = declared] = message.attachments
    assert ref["kind"] == "audio"

    assert UntrustedContent.attachment_sources([transcribed(declared)]) ==
             MapSet.new([{:attachment, "attached audio"}])
  end
end
