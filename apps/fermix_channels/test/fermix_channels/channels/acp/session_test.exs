defmodule FermixChannels.Channels.Acp.SessionTest do
  @moduledoc """
  Session state is plain data owned by the Peer (M29 §6.1): id minting, prompt
  folding (§8.2), and the per-turn chunk/fence bookkeeping (§8.4).
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Acp.Session

  describe "new/2" do
    test "mints an acp- prefixed 32-hex-character id" do
      session = Session.new("/tmp/work", "Fermix · #eng")

      assert %Session{cwd: "/tmp/work", title: "Fermix · #eng", turn: nil} = session
      assert <<"acp-", hex::binary-size(32)>> = session.id
      assert String.downcase(hex) == hex
      assert {:ok, _bytes} = Base.decode16(hex, case: :lower)
    end

    test "ids are unique across sessions" do
      ids = for _n <- 1..200, do: Session.new("/tmp", nil).id
      assert length(Enum.uniq(ids)) == 200
    end
  end

  describe "fold_prompt/1" do
    test "joins text blocks verbatim with a blank line" do
      blocks = [
        %{"type" => "text", "text" => "/sandbox grant /tmp/x"},
        %{"type" => "text", "text" => "please summarise"}
      ]

      assert {:ok, "/sandbox grant /tmp/x\n\nplease summarise"} = Session.fold_prompt(blocks)
    end

    test "renders a resource_link as a bracketed reference" do
      blocks = [
        %{"type" => "text", "text" => "read this"},
        %{"type" => "resource_link", "uri" => "file:///tmp/deploy.log", "name" => "deploy.log"}
      ]

      assert {:ok, folded} = Session.fold_prompt(blocks)
      assert folded == "read this\n\n[resource: file:///tmp/deploy.log (deploy.log)]"
    end

    test "refuses the capability-gated block types by name" do
      for type <- ~w(image audio resource) do
        assert {:error, {:unsupported_block, ^type}} =
                 Session.fold_prompt([%{"type" => type, "data" => "..."}])
      end
    end

    test "refuses an unknown block type" do
      assert {:error, {:unsupported_block, "video"}} =
               Session.fold_prompt([%{"type" => "video"}])
    end

    test "refuses a prompt with no content" do
      assert {:error, :empty_prompt} = Session.fold_prompt([])
      assert {:error, :empty_prompt} = Session.fold_prompt([%{"type" => "text", "text" => "  "}])
    end

    test "refuses a malformed block" do
      assert {:error, :malformed_prompt} = Session.fold_prompt(["hi"])
      assert {:error, :malformed_prompt} = Session.fold_prompt("hi")
      assert {:error, :malformed_prompt} = Session.fold_prompt([%{"type" => "text"}])
    end
  end

  describe "turn bookkeeping" do
    test "start_turn assigns a strictly increasing sequence" do
      session = Session.new("/tmp", nil)
      {session, first} = Session.start_turn(session, 1)
      session = Session.clear_turn(session)
      {_session, second} = Session.start_turn(session, 2)

      assert second > first
    end

    test "clear_turn closes the fence" do
      session = Session.new("/tmp", nil)
      {session, seq} = Session.start_turn(session, 7)

      assert Session.turn_open?(session, seq)
      refute Session.turn_open?(session, seq + 1)

      session = Session.clear_turn(session)
      refute Session.turn_open?(session, seq)
      assert session.turn == nil
    end

    test "unsent_suffix returns only what has not been written yet" do
      session = Session.new("/tmp", nil)
      {session, _seq} = Session.start_turn(session, 1)

      assert {"Hello", session} = Session.unsent_suffix(session, "Hello")
      assert {" world", session} = Session.unsent_suffix(session, "Hello world")
      assert {"", session} = Session.unsent_suffix(session, "Hello world")
      # A shorter snapshot never emits a negative-length slice.
      assert {"", _session} = Session.unsent_suffix(session, "Hi")
    end

    test "a new iteration restarts the cumulative baseline" do
      session = Session.new("/tmp", nil)
      {session, _seq} = Session.start_turn(session, 1)
      assert {"first pass", session} = Session.unsent_suffix(session, "first pass")

      session = Session.reset_stream(session)
      assert {"second pass", _session} = Session.unsent_suffix(session, "second pass")
    end

    test "tool call ids are minted per start and taken once at finish" do
      session = Session.new("/tmp", nil)
      {session, _seq} = Session.start_turn(session, 1)

      {"t1", session} = Session.start_tool(session, "shell")
      {"t2", session} = Session.start_tool(session, "web_search")

      assert {:ok, "t1", session} = Session.finish_tool(session, "shell")
      assert {:ok, "t2", session} = Session.finish_tool(session, "web_search")
      assert :error = Session.finish_tool(session, "shell")
    end
  end
end
