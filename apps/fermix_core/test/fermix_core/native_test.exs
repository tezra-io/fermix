defmodule FermixCore.NativeTest do
  @moduledoc """
  `Native.local_surface?/1`, the one answer to whether the person is at this
  computer (M76 §4.6), read off the two keys `TurnRunner` puts in every tool
  context: `channel` (`msg.channel`) and `computer_use_origin`, derived here by
  the real `TurnRunner.computer_use_origin/1` from the message a surface sends.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Agents.TurnRunner
  alias FermixCore.Native

  # The tool context's two keys, as TurnRunner's loop context builds them.
  defp turn_context(msg) do
    %{channel: msg.channel, computer_use_origin: TurnRunner.computer_use_origin(msg)}
  end

  defp voice_message do
    %{
      channel: "voice",
      source_trust: :operator,
      metadata: %{
        voice_call: %{
          call_id: "call-1",
          call_uuid: "uuid-1",
          conversation: "chat",
          conversation_key: {"companion", "owner", :root},
          delegation_id: "delegation-1",
          revision: 1,
          turn_session_id: "session-1",
          conversation_store: FermixCore.Agents.ConversationStore,
          prompt_addendum: "You are on a call.",
          persist?: true
        }
      }
    }
  end

  test "the Mac chat, fermix ask and an editor over ACP, attended, are this computer" do
    for channel <- ["companion", "cli", "acp"] do
      context = turn_context(%{channel: channel})

      assert context.computer_use_origin == :interactive
      assert Native.local_surface?(context), "#{channel} was not this computer"
    end
  end

  # A Buzz relay session is an ACP turn at :interactive, but a relay carries
  # other people (`Acp.Identity.multi_principal?/1`), so it is not proof the
  # person is at this computer; an editor's own session is.
  test "an ACP turn over a Buzz relay is not this computer; an editor's own session is" do
    relay =
      Map.put(turn_context(%{channel: "acp"}), :session_env, %{
        "BUZZ_RELAY_URL" => "wss://relay.example"
      })

    assert relay.computer_use_origin == :interactive
    refute Native.local_surface?(relay)

    editor = Map.put(turn_context(%{channel: "acp"}), :session_env, %{"PATH" => "/usr/bin"})
    assert Native.local_surface?(editor)
  end

  test "a Live voice call is this computer" do
    context = turn_context(voice_message())

    assert context.computer_use_origin == :voice
    assert Native.local_surface?(context)
  end

  # `computer_use_origin/1` marks every foreground chat turn `:interactive`, a
  # Telegram or phone turn included: attended is not proof the person is here.
  test "an attended Telegram turn is not this computer, nor any other chat or the phone" do
    for channel <- ["telegram", "slack", "discord", "signal", "whatsapp", "imessage", "mobile"] do
      context = turn_context(%{channel: channel})

      assert context.computer_use_origin == :interactive
      refute Native.local_surface?(context), "#{channel} was this computer"
    end
  end

  # A prompt on a local socket from a process the daemon started, or a
  # detached one, and an ACP notice re-ingested with no client: nobody is at
  # that terminal, so the socket being local does not make the turn local.
  test "a local socket's unattended turn is not this computer" do
    for msg <- [
          %{channel: "cli", metadata: %{caller: :daemon_descendant}},
          %{channel: "companion", metadata: %{caller: :detached}},
          %{channel: "acp", metadata: %{acp_turn: :detached}},
          %{channel: "background"}
        ] do
      context = turn_context(msg)

      assert context.computer_use_origin == :unattended
      refute Native.local_surface?(context), "#{inspect(msg)} was this computer"
    end
  end

  test "a voice channel without the trusted call is not this computer" do
    context = turn_context(%{channel: "voice", metadata: %{voice_call: %{call_id: "forged"}}})

    assert context.computer_use_origin == :interactive
    refute Native.local_surface?(context)
  end

  # A scheduled run omits the origin; absence is never read as presence.
  test "a context without an origin is not this computer, whatever its channel" do
    refute Native.local_surface?(%{channel: "companion"})
    refute Native.local_surface?(%{})
  end

  test "a context that is not a map is refused" do
    assert_raise FunctionClauseError, fn -> Native.local_surface?(channel: "cli") end
  end
end
