defmodule FermixCore.Computers.Capabilities.NotificationsTest do
  @moduledoc """
  `notifications` on a computer (M99 §10.1): the arguments it takes, the once
  per key rule, and its answers, against a replayed busctl standing in for
  this computer's session bus. Each test owns its table of shown keys and its
  clock; nothing reads this machine.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias FermixCore.Computers.Capabilities.Notifications, as: Capability
  alias FermixCore.NativeHost.Protocol

  @busctl "/usr/bin/busctl"
  @start ~U[2031-06-08 12:00:00.000Z]
  @day_ms 24 * 60 * 60_000

  @post %{
    "key" => "temporal:rem_1",
    "title" => "Tea",
    "body" => "Tea, today at 16:05.",
    "sound" => true,
    "reminder_id" => "rem_1"
  }

  # The computer's D-Bus backend against a busctl that answers `answers` by
  # member and tells this test each call.
  defp dbus(answers) do
    test = self()

    runner = fn @busctl, args ->
      member = Enum.find(["NameHasOwner", "Notify"], &(&1 in args))
      send(test, {:busctl, member})
      Map.fetch!(answers, member)
    end

    [
      placement: :here,
      provider: :dbus,
      runner: runner,
      find_executable: fn "busctl" -> @busctl end
    ]
  end

  defp showing, do: dbus(%{"NameHasOwner" => {:ok, "b true\n"}, "Notify" => {:ok, "u 7\n"}})

  defp context(native, clock \\ nil) do
    clock = clock || start_supervised!({Agent, fn -> @start end}, id: make_ref())

    %{
      id: "inv-#{System.unique_integer([:positive])}",
      origin: :background,
      epoch: 3,
      turn: %{session_id: "reminder-rem_1", tool_call_id: "inv-1"},
      home: "/nonexistent/computer-home",
      switches: [],
      clock: fn -> Agent.get(clock, & &1) end,
      deadline_ms: 15_000,
      notifications: %{shown: :ets.new(:shown, [:set, :public]), native: native}
    }
  end

  defp run(op, args, context), do: Capability.run(op, args, nil, context)

  describe "what it is" do
    test "the master switch alone gates it, and its ops are post and ready" do
      assert Capability.id() == :notifications
      assert Capability.offer() == nil
      assert Capability.ops() == ["post", "ready"]
      assert Capability.effect?("post")
      refute Capability.effect?("ready")
      refute Capability.long_lived?("post")
      refute Capability.long_lived?("ready")
      assert Capability.deadline_ms("post", @post) == 15_000
      assert Capability.deadline_ms("ready", %{}) == 10_000
      assert Capability.bounds("post") == %{result_bytes: 1_024, part_bytes: 0}
      assert Capability.admit("post", @post, %{}) == :ok
      assert Capability.label() == "notifications"
      assert Capability.op_label("post") == "show a notification"
      assert Capability.op_label("ready") == "check notifications"
      refute Capability.recorded?("ready", %{})
      assert Capability.recorded?("post", @post)
    end

    test "its target names the reminder, never the text" do
      assert Capability.target("post", @post) == "reminder rem_1"
      assert Capability.target("post", Map.delete(@post, "reminder_id")) == "notification"
      assert Capability.target("ready", %{}) == "notification"
    end
  end

  describe "validate/2" do
    test "a post takes its key, title, body and sound, and a reminder id or none" do
      assert Capability.validate("post", @post) == :ok
      assert Capability.validate("post", Map.delete(@post, "reminder_id")) == :ok
      assert Capability.validate("post", %{@post | "body" => ""}) == :ok
    end

    test "each argument is held to its bounds" do
      title = String.duplicate("é", Protocol.max_title_chars())
      body = String.duplicate("é", Protocol.max_body_chars())
      assert Capability.validate("post", %{@post | "title" => title, "body" => body}) == :ok

      refused = [
        Map.put(@post, "extra", 1),
        Map.delete(@post, "sound"),
        %{@post | "key" => ""},
        %{@post | "key" => "-starts-with-a-dash"},
        %{@post | "key" => "has space"},
        %{@post | "key" => String.duplicate("k", 129)},
        %{@post | "title" => ""},
        %{@post | "title" => title <> "é"},
        %{@post | "body" => body <> "é"},
        %{@post | "body" => <<0xFF>>},
        %{@post | "sound" => "yes"},
        %{@post | "reminder_id" => ""},
        %{@post | "reminder_id" => String.duplicate("r", 65)},
        %{@post | "reminder_id" => nil}
      ]

      for args <- refused do
        assert {:error, sentence} = Capability.validate("post", args), inspect(args)
        assert String.ends_with?(sentence, ".")
      end

      assert Capability.validate("post", %{@post | "key" => String.duplicate("k", 128)}) == :ok
    end

    test "ready takes nothing" do
      assert Capability.validate("ready", %{}) == :ok
      assert {:error, _sentence} = Capability.validate("ready", %{"key" => "x"})
    end
  end

  describe "post" do
    test "shows the notification through this computer's own backend, with sound" do
      context = context(showing())

      assert run("post", @post, context) == {:ok, %{"shown" => "now"}, nil}
      assert_received {:busctl, "NameHasOwner"}
      assert_received {:busctl, "Notify"}
    end

    test "a key shows once: asked again, it answers before and posts nothing" do
      context = context(showing())

      assert {:ok, %{"shown" => "now"}, nil} = run("post", @post, context)
      assert_received {:busctl, "NameHasOwner"}
      assert_received {:busctl, "Notify"}

      assert run("post", @post, context) == {:ok, %{"shown" => "before"}, nil}
      refute_received {:busctl, _member}
    end

    test "a post that failed releases its key, so the next ask posts again" do
      no_server = dbus(%{"NameHasOwner" => {:ok, "b false\n"}})
      context = context(no_server)

      assert {:failed, words, %{"reason" => "no_server"}, nil} = run("post", @post, context)
      assert words =~ "notification server"

      later = %{context | notifications: %{context.notifications | native: showing()}}
      assert run("post", @post, later) == {:ok, %{"shown" => "now"}, nil}
    end

    test "each failure answers its reason from the closed set, with the backend's words" do
      rows = [
        {[placement: :here, provider: :dbus, find_executable: fn "busctl" -> nil end],
         "backend_missing"},
        {dbus(%{"NameHasOwner" => {:error, :timeout}}), "timeout"},
        {dbus(%{
           "NameHasOwner" => {:ok, "b true\n"},
           "Notify" => {:error, {:helper_failed, 1, "Call failed: Invalid argument"}}
         }), "failed"}
      ]

      for {native, word} <- rows do
        assert {:failed, words, %{"reason" => ^word}, nil} = run("post", @post, context(native))
        assert is_binary(words) and words != ""
      end
    end

    test "a key is kept a day, then shows again" do
      clock = start_supervised!({Agent, fn -> @start end}, id: make_ref())
      context = context(showing(), clock)

      assert {:ok, %{"shown" => "now"}, nil} = run("post", @post, context)
      Agent.update(clock, &DateTime.add(&1, @day_ms - 1, :millisecond))
      assert {:ok, %{"shown" => "before"}, nil} = run("post", @post, context)
      Agent.update(clock, &DateTime.add(&1, 2, :millisecond))
      assert {:ok, %{"shown" => "now"}, nil} = run("post", @post, context)
    end

    test "at most 512 keys are kept: the oldest goes first" do
      clock = start_supervised!({Agent, fn -> @start end}, id: make_ref())
      context = context(showing(), clock)

      for n <- 1..512 do
        Agent.update(clock, &DateTime.add(&1, 1, :millisecond))
        assert {:ok, %{"shown" => "now"}, nil} = run("post", %{@post | "key" => "k#{n}"}, context)
      end

      assert :ets.info(context.notifications.shown, :size) == 512
      assert {:ok, %{"shown" => "before"}, nil} = run("post", %{@post | "key" => "k1"}, context)

      Agent.update(clock, &DateTime.add(&1, 1, :millisecond))
      assert {:ok, %{"shown" => "now"}, nil} = run("post", %{@post | "key" => "k513"}, context)
      assert :ets.info(context.notifications.shown, :size) == 512
      assert {:ok, %{"shown" => "now"}, nil} = run("post", %{@post | "key" => "k1"}, context)
      assert {:ok, %{"shown" => "before"}, nil} = run("post", %{@post | "key" => "k3"}, context)
    end

    test "a post carries no file" do
      assert {:failed, _words} = Capability.run("post", @post, "bytes", context(showing()))
    end
  end

  describe "ready" do
    test "answers ready, or the backend's own clause" do
      assert run("ready", %{}, context(dbus(%{"NameHasOwner" => {:ok, "b true\n"}}))) ==
               {:ok, %{"ready" => true}, nil}

      assert {:ok, %{"ready" => false, "sentence" => sentence}, nil} =
               run("ready", %{}, context(dbus(%{"NameHasOwner" => {:ok, "b false\n"}})))

      assert sentence == "no desktop notification server is running on this machine"
    end

    test "a sentence past 300 bytes is cut on a character boundary" do
      # The bus's own words, 200 two-byte characters once D-Bus has bounded them.
      long = {:error, {:helper_failed, 1, String.duplicate("é", 400)}}
      native = dbus(%{"NameHasOwner" => long})

      assert {:ok, %{"ready" => false, "sentence" => sentence}, nil} =
               run("ready", %{}, context(native))

      assert byte_size(sentence) in 290..300
      assert String.valid?(sentence)
      assert sentence =~ "the session bus could not be asked"
    end
  end
end
