defmodule FermixChannels.Gateway.MessageTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Gateway.Message

  describe "new!/1" do
    test "normalizes the shared inbound shape and defaults root thread scope" do
      message =
        Message.new!(%{
          id: "42",
          content: "hello",
          sender: "ada",
          channel: "telegram",
          chat_id: "-1001",
          reply_target: "-1001",
          metadata: %{raw: %{"message_id" => 42}},
          attachments: [%{type: :photo, file_id: "abc"}]
        })

      assert %Message{} = message
      assert message.thread_scope == :root
      assert message.metadata == %{raw: %{"message_id" => 42}}
      assert message.attachments == [%{type: :photo, file_id: "abc"}]
    end

    test "derives thread scope from thread_ts" do
      root_message =
        Message.new!(%{
          id: "42",
          content: "hello",
          sender: "ada",
          channel: "telegram",
          chat_id: "-1001",
          reply_target: "-1001",
          thread_ts: nil
        })

      thread_message =
        Message.new!(%{
          id: "43",
          content: "hello thread",
          sender: "ada",
          channel: "telegram",
          chat_id: "-1001",
          reply_target: "-1001",
          thread_ts: 99
        })

      assert root_message.thread_scope == :root
      assert thread_message.thread_scope == :thread
    end
  end

  # One helper records a forward the channel read: on the metadata stored with
  # the message, on each declared attachment, and as a label the model reads
  # before non-blank text. The owner's own message is returned as it came.
  describe "mark_forwarded/2" do
    defp forwardable(content) do
      Message.new!(%{
        id: "1",
        content: content,
        sender: "alice",
        channel: "telegram",
        chat_id: "42",
        reply_target: "42",
        metadata: %{chat_type: "private"},
        attachments: [%{hint: :photo, file_id: "p1"}]
      })
    end

    test "a forwarded message is marked on its metadata, attachments and text" do
      marked = Message.mark_forwarded(forwardable("meet at the dock"), true)

      assert marked.metadata == %{chat_type: "private", forwarded: true}
      assert [%{hint: :photo, forwarded?: true}] = marked.attachments
      assert marked.content == "[forwarded message]\nmeet at the dock"
    end

    test "a forwarded message with no text keeps its blank content" do
      assert Message.mark_forwarded(forwardable(""), true).content == ""
    end

    test "the owner's own message is returned unchanged" do
      owner = forwardable("meet at the dock")
      assert Message.mark_forwarded(owner, false) == owner
    end
  end

  describe "actionable?/1 and unusable_only?/1" do
    test "non-blank text is actionable" do
      assert Message.actionable?(message(content: "hello", inbound_attachments: []))
    end

    test "blank or whitespace-only text with no attachment is NOT actionable, and not unusable" do
      for content <- ["", "   \n  "] do
        msg = message(content: content, inbound_attachments: [])
        refute Message.actionable?(msg)
        refute Message.unusable_only?(msg)
      end
    end

    test "blank text with an attachment that reached the model IS actionable" do
      for status <- [:ready, :transcribed] do
        msg = message(content: "", inbound_attachments: [attachment(status)])
        assert Message.actionable?(msg)
        refute Message.unusable_only?(msg)
      end
    end

    test "blank text with only unusable attachments is unusable, never empty" do
      msg =
        message(
          content: "",
          inbound_attachments: [attachment({:unusable, {:unknown_type, "application/zip"}})]
        )

      refute Message.actionable?(msg)
      assert Message.unusable_only?(msg)
    end

    test "a video whose pictures could not be read is actionable when its sound reached the model" do
      clip = %{attachment({:unusable, {:needs_ffmpeg, :video}}) | kind: :video}

      heard =
        message(content: "", inbound_attachments: [%{clip | sound: {:transcript, "cheers"}}])

      silent = message(content: "", inbound_attachments: [%{clip | sound: :no_speech}])

      assert Message.actionable?(heard)
      refute Message.actionable?(silent)
      assert Message.unusable_only?(silent)
    end

    test "a caption makes a message with unusable attachments actionable (the manifest names them)" do
      msg =
        message(
          content: "thoughts?",
          inbound_attachments: [attachment({:unusable, {:needs_ffmpeg, :video}})]
        )

      assert Message.actionable?(msg)
      refute Message.unusable_only?(msg)
    end
  end

  defp attachment(status),
    do: %FermixCore.Attachments{kind: :still, mime_type: "image/png", status: status}

  defp message(fields) do
    Message.new!(
      Enum.into(fields, %{
        id: "i",
        content: "",
        sender: "u",
        channel: "telegram",
        chat_id: "c",
        reply_target: "c"
      })
    )
  end
end
