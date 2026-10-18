defmodule FermixCore.Native.Notifications.DBusTest do
  @moduledoc """
  The Linux notification backend (M76 §4.5) against a runner that replays
  `busctl`'s output: the owner question asked of the bus itself, the no-bus
  marks, a missing `busctl`, a name with no owner, and one `Notify` carrying
  what the server reads. No test runs `busctl` or reads this machine.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Native.Notifications.DBus

  @busctl "/usr/bin/busctl"
  @no_server "no desktop notification server is running on this machine"
  @notification %{title: "Tea", body: "Tea, today at 16:05.", sound: true}

  # busctl's own lines when there is no session bus to ask: no address at all
  # (a Debian 12 shell with neither variable set), and an address with nothing
  # behind it.
  @no_bus_outputs [
    "Failed to connect to bus: No such file or directory\n",
    "Failed to set bus address: $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined " <>
      "(consider using --machine=<user>@.host --user to connect to bus of other user)\n",
    "Failed to connect to bus: Connection refused\n"
  ]

  @name_has_owner [
    "--user",
    "--timeout=1",
    "--",
    "call",
    "org.freedesktop.DBus",
    "/org/freedesktop/DBus",
    "org.freedesktop.DBus",
    "NameHasOwner",
    "s",
    "org.freedesktop.Notifications"
  ]

  # A runner that answers each busctl call from a script keyed by the D-Bus
  # member asked, and records every call, so a test pins both the answer and
  # that nothing beyond the expected calls ran.
  defp scripted(answers) do
    test_pid = self()

    fn @busctl, args ->
      send(test_pid, {:busctl, args})
      member = Enum.find(["NameHasOwner", "Notify"], &(&1 in args))
      Map.fetch!(answers, member)
    end
  end

  defp opts(answers),
    do: [runner: scripted(answers), find_executable: fn "busctl" -> @busctl end]

  defp no_busctl do
    [
      runner: fn _busctl, _args -> flunk("busctl ran though it is not installed") end,
      find_executable: fn "busctl" -> nil end
    ]
  end

  defp owned(notify_answer),
    do: opts(%{"NameHasOwner" => {:ok, "b true\n"}, "Notify" => notify_answer})

  describe "ready/2" do
    test "a server that owns the name is ready, asked of the bus itself" do
      assert DBus.ready(%{}, opts(%{"NameHasOwner" => {:ok, "b true\n"}})) == :ok

      # The bus answers, not the service, so an activatable server is not
      # started by the asking.
      assert_received {:busctl, @name_has_owner}
      refute_received {:busctl, _second}
    end

    test "no owner of the name is the sentence a headless or logged-out host gets" do
      assert DBus.ready(%{}, opts(%{"NameHasOwner" => {:ok, "b false\n"}})) ==
               {:error, @no_server}
    end

    test "a session bus that cannot be reached answers the same sentence" do
      for output <- @no_bus_outputs do
        answers = %{"NameHasOwner" => {:error, {:helper_failed, 1, output}}}
        assert DBus.ready(%{}, opts(answers)) == {:error, @no_server}, output
      end
    end

    test "a missing busctl refuses and runs nothing" do
      assert {:error, sentence} = DBus.ready(%{}, no_busctl())
      assert sentence =~ "busctl is not installed"
    end

    test "a question that times out refuses, never a guess" do
      assert {:error, sentence} = DBus.ready(%{}, opts(%{"NameHasOwner" => {:error, :timeout}}))
      assert sentence =~ "did not answer in time"
    end

    test "an answer it cannot read refuses with bounded evidence" do
      long = String.duplicate("x", 1_000)

      for answer <- [{:ok, ~s(s "yes"\n)}, {:error, {:helper_failed, 1, long <> "\nsecond line"}}] do
        assert {:error, sentence} = DBus.ready(%{}, opts(%{"NameHasOwner" => answer}))
        assert sentence =~ "NameHasOwner"
        assert String.length(sentence) <= 320
        refute sentence =~ "second line"
      end
    end
  end

  describe "post/2" do
    test "one Notify once the name has an owner, carrying what the server reads" do
      assert DBus.post(@notification, owned({:ok, "u 42\n"})) == {:ok, "42"}

      assert_received {:busctl, @name_has_owner}

      assert_received {:busctl,
       [
         "--user",
         "--timeout=1",
         "--",
         "call",
         "org.freedesktop.Notifications",
         "/org/freedesktop/Notifications",
         "org.freedesktop.Notifications",
         "Notify",
         "susssasa{sv}i",
         # app_name, replaces_id, app_icon, summary, body
         "Fermix",
         "0",
         "",
         "Tea",
         "Tea, today at 16:05.",
         # no actions
         "0",
         # three hints
         "3",
         "desktop-entry",
         "s",
         "io.tezra.Fermix",
         "urgency",
         "y",
         "1",
         "sound-name",
         "s",
         "alarm-clock-elapsed",
         # the server's default timeout
         "-1"
       ]}

      refute_received {:busctl, _third}
    end

    test "a quiet notification asks the server for no sound" do
      assert {:ok, "7"} = DBus.post(%{@notification | sound: false}, owned({:ok, "u 7\n"}))

      assert_received {:busctl, @name_has_owner}
      assert_received {:busctl, notify}
      assert ["suppress-sound", "b", "true", "-1"] == Enum.take(notify, -4)
      refute "sound-name" in notify
    end

    # The expiry is a negative integer and the text is the owner's: both sit
    # after busctl's `--`, so neither can be read as an option.
    test "text that starts with a dash stays an argument" do
      notification = %{@notification | title: "-v", body: "--help"}
      assert {:ok, "9"} = DBus.post(notification, owned({:ok, "u 9\n"}))

      assert_received {:busctl, _owner}
      assert_received {:busctl, ["--user", "--timeout=1", "--", "call" | rest]}
      assert ["-v", "--help"] == rest |> Enum.drop(8) |> Enum.take(2)
    end

    test "no owner of the name is no_server, and no Notify is sent" do
      assert DBus.post(@notification, opts(%{"NameHasOwner" => {:ok, "b false\n"}})) ==
               {:error, :no_server}

      assert_received {:busctl, @name_has_owner}
      refute_received {:busctl, _notify}
    end

    test "no session bus is no_server, before or between the calls" do
      for output <- @no_bus_outputs do
        failed = {:error, {:helper_failed, 1, output}}

        assert DBus.post(@notification, opts(%{"NameHasOwner" => failed})) ==
                 {:error, :no_server}

        assert DBus.post(@notification, owned(failed)) == {:error, :no_server}
      end
    end

    test "a missing busctl is backend_missing, and nothing runs" do
      assert DBus.post(@notification, no_busctl()) == {:error, :backend_missing}
    end

    test "a call that times out is timeout" do
      assert DBus.post(@notification, opts(%{"NameHasOwner" => {:error, :timeout}})) ==
               {:error, :timeout}

      assert DBus.post(@notification, owned({:error, :timeout})) == {:error, :timeout}
    end

    test "a Notify the server refuses fails with its words, bounded" do
      refused = {:error, {:helper_failed, 1, "Call failed: Invalid argument\nmore"}}

      assert {:error, {:failed, evidence}} = DBus.post(@notification, owned(refused))
      assert evidence == "Notify: exit 1: Call failed: Invalid argument"
    end

    test "an answer that is not a notification id fails with it" do
      for answer <- [{:ok, "u 0\n"}, {:ok, ~s(s "queued"\n)}] do
        assert {:error, {:failed, evidence}} = DBus.post(@notification, owned(answer))
        assert evidence =~ "Notify: unexpected output"
      end
    end

    test "a notification without its title, body or sound flag is refused" do
      for notification <- [
            %{body: "b", sound: true},
            %{@notification | title: ""},
            %{@notification | sound: "yes"}
          ] do
        assert_raise FunctionClauseError, fn -> DBus.post(notification, no_busctl()) end
      end
    end
  end
end
