defmodule FermixCore.Native.NotificationsTest do
  @moduledoc """
  The notification service (M76 §4.3, §4.6): the backend each build resolves,
  the readiness and the post it delegates, and the delivery adapter the
  reminder rail resolves for platform `"computer"`, with every failure in
  `Delivery.Error`'s closed vocabulary. The D-Bus backend runs against a
  replayed `busctl`; nothing reads this machine.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.Error
  alias FermixCore.Native.Notifications
  alias FermixCore.Native.Notifications.DBus

  @busctl "/usr/bin/busctl"
  @brew_mac %{profile: :standalone_cli, os: :darwin}
  @mac_checkout %{profile: :source, os: :darwin}
  @no_server "no desktop notification server is running on this machine"
  @text "Tea, today at 16:05."
  @notification %{title: "Tea", body: @text, sound: true}

  @brew_sentence "this build (the standalone Fermix, a Homebrew formula or a downloaded " <>
                   "binary) shows no notifications on this Mac; the Fermix app does, and " <>
                   "fermix migrate-to-app moves this install to it"

  defp scripted(answers) do
    test_pid = self()

    fn @busctl, args ->
      send(test_pid, {:busctl, args})
      member = Enum.find(["NameHasOwner", "Notify"], &(&1 in args))
      Map.fetch!(answers, member)
    end
  end

  # The D-Bus backend, named, against a scripted busctl.
  defp dbus(answers) do
    [provider: :dbus, runner: scripted(answers), find_executable: fn "busctl" -> @busctl end]
  end

  defp server(notify_answer),
    do: dbus(%{"NameHasOwner" => {:ok, "b true\n"}, "Notify" => notify_answer})

  defp nothing_runs do
    [
      runner: fn _busctl, _args -> flunk("busctl ran") end,
      find_executable: fn "busctl" -> flunk("busctl was looked for") end
    ]
  end

  describe "resolve/1" do
    test "on every Linux build the host decides D-Bus" do
      for profile <- [:app_engine, :standalone_cli, :linux_package_cli, :source] do
        assert Notifications.resolve(host: %{profile: profile, os: :linux}) ==
                 {:ok, %{provider: :dbus, module: DBus, source: :build}}
      end
    end

    test "a named provider decides, and the resolution says so" do
      assert Notifications.resolve(provider: :dbus, host: @brew_mac) ==
               {:ok, %{provider: :dbus, module: DBus, source: :given}}
    end

    test "a build that offers none refuses, naming the build" do
      assert Notifications.resolve(host: @brew_mac) == {:error, @brew_sentence}

      assert Notifications.resolve(host: @mac_checkout) ==
               {:error,
                "this build (a development run from a source checkout) shows no " <>
                  "notifications on this Mac; the Fermix app's own engine does"}

      assert Notifications.resolve(provider: :none, host: @brew_mac) == {:error, @brew_sentence}
    end
  end

  describe "ready/2" do
    test "on Linux it is the session bus's answer" do
      assert Notifications.ready(%{}, dbus(%{"NameHasOwner" => {:ok, "b true\n"}})) == :ok

      assert Notifications.ready(%{}, dbus(%{"NameHasOwner" => {:ok, "b false\n"}})) ==
               {:error, @no_server}
    end

    test "a build that offers none is not ready, and asks nothing" do
      assert Notifications.ready(%{}, [host: @brew_mac] ++ nothing_runs()) ==
               {:error, @brew_sentence}
    end
  end

  describe "post/2" do
    test "posts through the resolved backend and answers its id" do
      assert Notifications.post(@notification, server({:ok, "u 42\n"})) == {:ok, "42"}
    end

    test "a build that offers none is not_offered, and nothing substitutes" do
      assert Notifications.post(@notification, [host: @brew_mac] ++ nothing_runs()) ==
               {:error, :not_offered}
    end

    test "a malformed notification is refused before any backend" do
      # Dynamic dispatch so the type checker doesn't flag the deliberately
      # malformed map at compile time.
      assert_raise FunctionClauseError, fn ->
        apply(Notifications, :post, [
          %{title: "Tea", body: @text},
          [host: @brew_mac] ++ nothing_runs()
        ])
      end
    end
  end

  describe "send_message/3, the computer delivery adapter" do
    test "a due reminder rings: the title as summary, the rendered text as body, with sound" do
      send_opts = [title: "Tea", proactive_key: "temporal:r1"] ++ server({:ok, "u 42\n"})

      assert Notifications.send_message("local", @text, send_opts) == :ok

      assert_received {:busctl, _owner}
      assert_received {:busctl, notify}
      assert ["Tea", @text] == notify |> Enum.drop(12) |> Enum.take(2)

      assert ["sound-name", "s", "alarm-clock-elapsed"] ==
               notify |> Enum.drop(-1) |> Enum.take(-3)
    end

    test "each Linux failure lands in the closed vocabulary" do
      no_bus =
        {:error, {:helper_failed, 1, "Failed to connect to bus: No such file or directory"}}

      rows = [
        {dbus(%{"NameHasOwner" => no_bus}), {:transport, :connection_refused}},
        {dbus(%{"NameHasOwner" => {:ok, "b false\n"}}), {:transport, :connection_refused}},
        {[provider: :dbus, find_executable: fn "busctl" -> nil end],
         {:permanent, :adapter_unavailable}},
        {dbus(%{"NameHasOwner" => {:error, :timeout}}), {:transport, :timeout}},
        {server({:error, {:helper_failed, 1, "Call failed: Invalid argument"}}),
         {:permanent, :remote_rejected}},
        {[host: @brew_mac] ++ nothing_runs(), {:permanent, :adapter_unavailable}}
      ]

      for {opts, error} <- rows do
        assert Notifications.send_message("local", @text, [title: "Tea"] ++ opts) ==
                 {:error, error}
      end
    end

    test "a destination other than this computer's is refused before any call" do
      assert Notifications.send_message("chat-1", @text, [title: "Tea"] ++ nothing_runs()) ==
               {:error, {:permanent, :invalid_destination}}
    end

    test "a delivery without the event's title is refused before any call" do
      for opts <- [[], [title: ""], [title: nil]] do
        assert Notifications.send_message("local", @text, opts ++ nothing_runs()) ==
                 {:error, {:permanent, :malformed_request}}
      end
    end
  end

  describe "delivery_error/1" do
    # M76 §4.6's table, a row per reason a backend answers, and whether the
    # rail's ladder retries it on the same target.
    @rows [
      {:host_unavailable, {:transport, :timeout}, true},
      {:not_authorized, {:permanent, :authorization}, false},
      {:no_server, {:transport, :connection_refused}, true},
      {:backend_missing, {:permanent, :adapter_unavailable}, false},
      {:not_offered, {:permanent, :adapter_unavailable}, false},
      {:timeout, {:transport, :timeout}, true},
      {{:failed, "Notify: exit 1: Call failed"}, {:permanent, :remote_rejected}, false}
    ]

    test "every reason maps to one error of the closed vocabulary, retried as the table says" do
      for {reason, error, retried?} <- @rows do
        assert Notifications.delivery_error(reason) == error, inspect(reason)
        assert Error.normalize({:error, error}) == {:error, error}, inspect(error)
        assert Error.retryable?(error) == retried?, inspect(error)
      end
    end

    test "a reason outside the vocabulary is refused" do
      # Dynamic dispatch so the type checker doesn't flag the deliberately
      # off-contract reason at compile time; the fail-loud behavior is what we assert.
      assert_raise FunctionClauseError, fn ->
        apply(Notifications, :delivery_error, [:busy])
      end
    end
  end

  describe "through ChannelSend, as the reminder rail sends" do
    @channels %{"computer" => Notifications}

    test "the computer platform resolves to the adapter" do
      assert Notifications.platform() == "computer"
      assert Notifications.destination() == "local"

      assert ChannelSend.resolve_adapter(Notifications.platform(), channels: @channels) ==
               {:ok, Notifications}
    end

    test "one bounded send reaches the server, and a refusal normalizes as the rail reads it" do
      delivered =
        rail_send([title: "Tea", proactive_key: "temporal:r1"] ++ server({:ok, "u 3\n"}))

      assert delivered == :ok

      refused = rail_send([title: "Tea"] ++ dbus(%{"NameHasOwner" => {:ok, "b false\n"}}))
      assert refused == {:error, {:transport, :connection_refused}}
    end

    # `Temporal.Delivery.attempt/5`'s shape: one send under the watchdog, its
    # whole result normalized.
    defp rail_send(send_opts) do
      30_000
      |> ChannelSend.with_timeout(fn ->
        ChannelSend.send(
          Notifications.platform(),
          Notifications.destination(),
          @text,
          send_opts,
          channels: @channels,
          delivery_max_attempts: 1
        )
      end)
      |> Error.normalize()
    end
  end

  @config_exs Path.expand("../../../../../config/config.exs", __DIR__)

  # The reminder rail resolves a stored `computer` row's adapter from the
  # shipped channels map at every attempt, so the map names this module beside
  # the chat platforms. A build that offers no notifications still resolves it
  # and answers its own refusal, never a missing adapter.
  test "the shipped delivery channels map the computer platform to this adapter" do
    channels =
      @config_exs
      |> Config.Reader.read!(env: :prod, target: :host)
      |> Keyword.fetch!(:fermix_core)
      |> Keyword.fetch!(:jobs)
      |> Keyword.fetch!(:delivery_channels)

    assert Map.fetch!(channels, Notifications.platform()) == Notifications
  end
end
