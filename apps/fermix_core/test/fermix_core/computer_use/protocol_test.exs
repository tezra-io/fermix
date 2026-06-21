defmodule FermixCore.ComputerUse.ProtocolTest do
  use ExUnit.Case, async: true

  alias FermixCore.ComputerUse.Protocol

  describe "read_only?/1" do
    test "screenshot, mouse_move, and wait are read-only" do
      for action <- ~w(screenshot mouse_move wait), do: assert(Protocol.read_only?(action))
    end

    test "clicks, type, key, drag, scroll are NOT read-only" do
      for action <- ~w(left_click right_click double_click left_click_drag scroll type key) do
        refute Protocol.read_only?(action)
      end
    end
  end

  describe "validate/1 — valid actions" do
    test "screenshot with no args" do
      assert {:ok, %{"action" => "screenshot"}} = Protocol.validate(%{"action" => "screenshot"})
    end

    test "screenshot carries an optional display" do
      assert {:ok, %{"action" => "screenshot", "display" => 1}} =
               Protocol.validate(%{"action" => "screenshot", "display" => 1})
    end

    test "left_click with coordinates and modifiers" do
      assert {:ok, req} =
               Protocol.validate(%{
                 "action" => "left_click",
                 "x" => 100,
                 "y" => 200,
                 "modifiers" => ["cmd"]
               })

      assert req == %{"action" => "left_click", "x" => 100, "y" => 200, "modifiers" => ["cmd"]}
    end

    test "mouse_move omits an empty modifiers list" do
      assert {:ok, req} = Protocol.validate(%{"action" => "mouse_move", "x" => 0, "y" => 0})
      assert req == %{"action" => "mouse_move", "x" => 0, "y" => 0}
      refute Map.has_key?(req, "modifiers")
    end

    test "left_click_drag with from/to points" do
      assert {:ok, req} =
               Protocol.validate(%{
                 "action" => "left_click_drag",
                 "from" => %{"x" => 1, "y" => 2},
                 "to" => %{"x" => 3, "y" => 4}
               })

      assert req["from"] == %{"x" => 1, "y" => 2}
      assert req["to"] == %{"x" => 3, "y" => 4}
    end

    test "scroll with direction and amount" do
      assert {:ok, req} =
               Protocol.validate(%{
                 "action" => "scroll",
                 "x" => 10,
                 "y" => 20,
                 "direction" => "down",
                 "amount" => 3
               })

      assert req["direction"] == "down"
      assert req["amount"] == 3
    end

    test "type with bounded text" do
      assert {:ok, %{"action" => "type", "text" => "hello"}} =
               Protocol.validate(%{"action" => "type", "text" => "hello"})
    end

    test "key with a chord" do
      assert {:ok, %{"action" => "key", "chord" => "ctrl+s"}} =
               Protocol.validate(%{"action" => "key", "chord" => "ctrl+s"})
    end

    test "wait with bounded ms" do
      assert {:ok, %{"action" => "wait", "ms" => 500}} =
               Protocol.validate(%{"action" => "wait", "ms" => 500})
    end
  end

  describe "validate/1 — fail-loud rejections" do
    test "missing action" do
      assert {:error, "missing required field: action"} = Protocol.validate(%{})
    end

    test "unknown action" do
      assert {:error, "unknown action: " <> _} = Protocol.validate(%{"action" => "teleport"})
    end

    test "non-map params" do
      assert {:error, _} = Protocol.validate("left_click")
    end

    test "click with a negative coordinate" do
      assert {:error, msg} = Protocol.validate(%{"action" => "left_click", "x" => -1, "y" => 0})
      assert msg =~ "non-negative integer"
    end

    test "click with a non-integer coordinate" do
      assert {:error, _} = Protocol.validate(%{"action" => "left_click", "x" => 1.5, "y" => 0})
    end

    test "unknown modifier" do
      assert {:error, msg} =
               Protocol.validate(%{
                 "action" => "left_click",
                 "x" => 0,
                 "y" => 0,
                 "modifiers" => ["meta"]
               })

      assert msg =~ "modifiers must be a subset"
    end

    test "scroll with an invalid direction" do
      assert {:error, msg} =
               Protocol.validate(%{
                 "action" => "scroll",
                 "x" => 0,
                 "y" => 0,
                 "direction" => "sideways",
                 "amount" => 1
               })

      assert msg =~ "scroll.direction"
    end

    test "type with empty text" do
      assert {:error, _} = Protocol.validate(%{"action" => "type", "text" => ""})
    end

    test "type over the byte cap" do
      big = String.duplicate("a", 10_001)
      assert {:error, msg} = Protocol.validate(%{"action" => "type", "text" => big})
      assert msg =~ "bytes"
    end

    test "key with a blank chord" do
      assert {:error, _} = Protocol.validate(%{"action" => "key", "chord" => ""})
    end

    test "wait over the cap" do
      assert {:error, msg} = Protocol.validate(%{"action" => "wait", "ms" => 999_999})
      assert msg =~ "wait.ms"
    end

    test "drag with a malformed point" do
      assert {:error, msg} =
               Protocol.validate(%{
                 "action" => "left_click_drag",
                 "from" => %{"x" => 1},
                 "to" => %{"x" => 3, "y" => 4}
               })

      assert msg =~ "from"
    end
  end

  describe "encode_request/1 and decode_response/1" do
    test "encode_request produces a single newline-terminated JSON line" do
      line = Protocol.encode_request(%{"action" => "screenshot"})
      assert String.ends_with?(line, "\n")
      assert Jason.decode!(line) == %{"action" => "screenshot"}
    end

    test "decode_response accepts an ok response" do
      assert {:ok, %{"ok" => true, "width" => 1280}} =
               Protocol.decode_response(~s({"ok":true,"width":1280}\n))
    end

    test "decode_response surfaces an ok:false error" do
      assert {:error, "permission denied"} =
               Protocol.decode_response(~s({"ok":false,"error":"permission denied"}))
    end

    test "decode_response fails loud on invalid JSON" do
      assert {:error, msg} = Protocol.decode_response("not json")
      assert msg =~ "invalid JSON"
    end

    test "decode_response fails loud on a response with neither ok nor error" do
      assert {:error, msg} = Protocol.decode_response(~s({"status":"weird"}))
      assert msg =~ "malformed sidecar response"
    end
  end
end
