defmodule FermixChannels.Accessories.SerialTest do
  @moduledoc false
  # The USB serial transport, against pseudo-terminals only: no test here opens
  # a real serial device. A small Python double opens a pty, hands its slave
  # path to the test and relays the master's bytes over its own stdio, so the
  # test plays the accessory. The helper is macOS-only, so the pty tests run on
  # macOS and are skipped elsewhere with the reason printed; on macOS a missing
  # helper or python3 fails them.
  use ExUnit.Case, async: true

  alias FermixChannels.Accessories.Serial

  @darwin? :os.type() == {:unix, :darwin}
  @pty_skip if(@darwin?,
              do: false,
              else: "needs macOS: fermix_serial and its pseudo-terminal double are macOS-only"
            )

  # Process starts and helper exits are process work: a named bound well over
  # the suite default, for a busy runner.
  @process_bound 10_000

  # Interposed into the helper with DYLD_INSERT_LIBRARIES: records the calls
  # that touch the control lines, and answers the modem-line ioctls as a USB
  # serial port would, on a pseudo-terminal that has no lines.
  @line_recorder """
  #define _DARWIN_C_SOURCE 1
  #include <fcntl.h>
  #include <stdarg.h>
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include <sys/ioctl.h>
  #include <termios.h>
  #include <unistd.h>

  static void note(const char *text) {
    const char *path = getenv("FX_LINE_LOG");
    int fd = path == NULL ? -1 : open(path, O_WRONLY | O_APPEND | O_CREAT, 0600);
    if (fd < 0) abort();
    if (write(fd, text, strlen(text)) < 0 || write(fd, "\\n", 1) < 0) abort();
    close(fd);
  }

  static const char *line_name(void *arg) {
    int bits = *(int *)arg;
    return bits == TIOCM_RTS ? "RTS" : bits == TIOCM_DTR ? "DTR" : "OTHER";
  }

  static int fx_ioctl(int fd, unsigned long request, ...) {
    char text[64];
    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    if (request == TIOCMBIC || request == TIOCMBIS || request == TIOCMSET) {
      const char *name = request == TIOCMBIC ? "TIOCMBIC" : request == TIOCMBIS ? "TIOCMBIS" : "TIOCMSET";
      snprintf(text, sizeof text, "%s %s", name, line_name(arg));
      note(text);
      return 0;
    }
    if (request == TIOCSDTR || request == TIOCCDTR || request == TIOCMGET) {
      note("other line ioctl");
      return 0;
    }
    if (request == TIOCEXCL) note("TIOCEXCL");
    return ioctl(fd, request, arg);
  }

  static int fx_tcsetattr(int fd, int action, const struct termios *t) {
    char text[64];
    snprintf(text, sizeof text, "tcsetattr ispeed=%lu ospeed=%lu",
             (unsigned long)cfgetispeed(t), (unsigned long)cfgetospeed(t));
    note(text);
    return tcsetattr(fd, action, t);
  }

  static int fx_tcflush(int fd, int queue) {
    note(queue == TCIFLUSH ? "tcflush TCIFLUSH" : "tcflush OTHER");
    return tcflush(fd, queue);
  }

  __attribute__((used)) static const struct { const void *with; const void *instead_of; }
      interposers[] __attribute__((section("__DATA,__interpose"))) = {
          {(const void *)fx_ioctl, (const void *)ioctl},
          {(const void *)fx_tcsetattr, (const void *)tcsetattr},
          {(const void *)fx_tcflush, (const void *)tcflush},
  };
  """

  setup_all do
    unless @darwin?, do: IO.puts("#{inspect(__MODULE__)}: pty tests skipped: #{@pty_skip}")
    :ok
  end

  describe "spawn_plan/3" do
    test "on macOS the helper runs through the disclaim shim" do
      assert Serial.spawn_plan("/priv/fermix_serial", {:unix, :darwin}, "/priv/disclaim") ==
               {:ok, {"/priv/disclaim", ["/priv/fermix_serial"]}}
    end

    test "on macOS without the shim it refuses, with no undisclaimed spawn" do
      assert {:error, reason} = Serial.spawn_plan("/priv/fermix_serial", {:unix, :darwin}, nil)
      assert reason =~ "disclaim"
    end

    test "any other OS has no serial transport" do
      assert {:error, reason} = Serial.spawn_plan("/priv/fermix_serial", {:unix, :linux}, nil)
      assert reason =~ "macOS"
    end

    test "a build without the helper refuses" do
      assert {:error, reason} = Serial.spawn_plan(nil, {:unix, :darwin}, "/priv/disclaim")
      assert reason =~ "fermix_serial"
    end
  end

  describe "unavailable" do
    @describetag :tmp_dir

    test "another OS opens nothing and lists nothing, even with a helper that would answer",
         %{tmp_dir: dir} do
      stub = answering_stub(dir)
      opts = [helper_path: stub, shim_path: stub, os_type: {:unix, :linux}]

      assert {:error, {:unavailable, _why}} = Serial.open(Path.join(dir, "port"), opts)
      assert {:error, {:unavailable, _why}} = Serial.enumerate(opts)
      assert Process.info(self(), :links) == {:links, []}
      refute_received _anything
    end

    test "macOS without the disclaim shim opens nothing", %{tmp_dir: dir} do
      stub = answering_stub(dir)

      opts = [
        helper_path: stub,
        shim_path: Path.join(dir, "absent-disclaim"),
        os_type: {:unix, :darwin}
      ]

      assert {:error, {:unavailable, _why}} = Serial.open(Path.join(dir, "port"), opts)
      assert {:error, {:unavailable, _why}} = Serial.enumerate(opts)
      assert Process.info(self(), :links) == {:links, []}
      refute_received _anything
    end

    test "a build without the helper opens nothing", %{tmp_dir: dir} do
      opts = [helper_path: Path.join(dir, "absent-helper"), shim_path: answering_stub(dir)]

      assert {:error, {:unavailable, _why}} = Serial.open(Path.join(dir, "port"), opts)
      assert {:error, {:unavailable, _why}} = Serial.enumerate(opts)
      assert Process.info(self(), :links) == {:links, []}
    end
  end

  describe "decode_list/1" do
    test "decodes each port with what it reported" do
      packets = [
        port_packet(3, 0x303A, 0x1001, "/dev/cu.usbmodem9101", "80:45:6B:00:00:01"),
        port_packet(0, 0, 0, "/dev/cu.debug-console", ""),
        port_packet(1, 0x10C4, 0xEA60, "/dev/cu.usbserial-0001", ""),
        port_packet(2, 0, 0, "/dev/cu.other", "SER-1"),
        <<"Z", 4::16>>
      ]

      assert Serial.decode_list(packets) ==
               {:ok,
                [
                  %{
                    path: "/dev/cu.usbmodem9101",
                    vendor_id: 0x303A,
                    product_id: 0x1001,
                    serial: "80:45:6B:00:00:01"
                  },
                  %{path: "/dev/cu.debug-console", vendor_id: nil, product_id: nil, serial: nil},
                  %{
                    path: "/dev/cu.usbserial-0001",
                    vendor_id: 0x10C4,
                    product_id: 0xEA60,
                    serial: nil
                  },
                  %{path: "/dev/cu.other", vendor_id: nil, product_id: nil, serial: "SER-1"}
                ]}
    end

    test "an empty listing is an empty list" do
      assert Serial.decode_list([<<"Z", 0::16>>]) == {:ok, []}
    end

    test "any malformed packet fails the whole listing" do
      good = port_packet(3, 0x303A, 0x1001, "/dev/cu.a", "s")

      for packets <- [
            [],
            [good],
            [good, <<"Z", 2::16>>],
            [good, <<"Z", 1::16>>, <<"Z", 1::16>>],
            [<<"Z", 0::16, 0>>],
            [port_packet(4, 0, 0, "/dev/cu.a", ""), <<"Z", 1::16>>],
            [port_packet(0, 1, 0, "/dev/cu.a", ""), <<"Z", 1::16>>],
            [port_packet(0, 0, 0, "/dev/cu.a", "s"), <<"Z", 1::16>>],
            [port_packet(0, 0, 0, "", ""), <<"Z", 1::16>>],
            [port_packet(0, 0, 0, <<0xFF, 0xFE>>, ""), <<"Z", 1::16>>],
            [port_packet(2, 0, 0, "/dev/cu.a", <<0xC3>>), <<"Z", 1::16>>],
            [binary_part(good, 0, byte_size(good) - 1), <<"Z", 1::16>>],
            [good <> <<0>>, <<"Z", 1::16>>],
            [<<"Q">>, <<"Z", 0::16>>],
            [<<"Ebusy">>]
          ] do
        assert {:error, {:bad_list, _why}} = Serial.decode_list(packets), inspect(packets)
      end
    end

    test "more ports than the helper may report fails the listing" do
      ports = for n <- 1..65, do: port_packet(0, 0, 0, "/dev/cu.p#{n}", "")
      assert {:error, {:bad_list, _why}} = Serial.decode_list(ports ++ [<<"Z", 65::16>>])
    end
  end

  describe "on a pseudo-terminal" do
    @describetag skip: @pty_skip
    @describetag :tmp_dir

    setup do
      helper = Application.app_dir(:fermix_nif, "priv/fermix_serial")
      assert File.regular?(helper), "fermix_serial is not built at #{helper}: run mix compile"
      python = System.find_executable("python3")
      assert python, "python3 is needed for the pseudo-terminal double"

      double =
        Port.open({:spawn_executable, python}, [
          :binary,
          {:packet, 4},
          :exit_status,
          args: ["-I", "-c", FermixTestSupport.AccessoryPty.script()]
        ])

      assert_receive {^double, {:data, "S" <> slave}}, @process_bound
      %{double: double, slave: slave}
    end

    test "opens with the lines absent and relays raw bytes both ways", ctx do
      assert {:ok, handle} = Serial.open(ctx.slave, open_timeout_ms: @process_bound)
      assert handle.modem_lines == :absent
      assert handle.path == ctx.slave

      to_device = all_byte_values(20_000)
      assert :ok = Serial.write(handle, [])

      assert :ok =
               Serial.write(handle, [
                 binary_part(to_device, 0, 7),
                 binary_part(to_device, 7, 19_993)
               ])

      assert receive_at_double(ctx.double, byte_size(to_device), []) == to_device

      to_host =
        all_byte_values(20_000)
        |> :binary.bin_to_list()
        |> Enum.reverse()
        |> :binary.list_to_bin()

      Port.command(ctx.double, ["W", to_host])
      {received, reads} = receive_from_helper(handle, byte_size(to_host), [], 0)
      assert received == to_host
      assert reads > 1, "the helper reads at most 4,096 bytes at a time"

      assert :ok = Serial.close(handle)
    end

    test "a second opener of the same port is refused busy", ctx do
      assert {:ok, first} = Serial.open(ctx.slave, open_timeout_ms: @process_bound)
      # On a pty the refusal comes from the helper's flock: macOS does not
      # enforce TIOCEXCL on pseudo-terminals, as it does on USB serial ports.
      assert Serial.open(ctx.slave, open_timeout_ms: @process_bound) == {:error, :busy}
      assert :ok = Serial.close(first)
    end

    test "the peer going away arrives as vanished, and nothing after it", ctx do
      assert {:ok, handle} = Serial.open(ctx.slave, open_timeout_ms: @process_bound)
      Port.command(ctx.double, "C")

      assert next_transport_message(handle) == {:closed, :vanished}
      port = handle.port
      refute_received {^port, _message}
      assert :ok = Serial.close(handle)
      assert Serial.write(handle, "late") == {:error, :closed}
    end

    test "after the port goes the helper reads on until its port closes, so a late write is safe",
         ctx do
      assert {:ok, handle} = Serial.open(ctx.slave, open_timeout_ms: @process_bound)
      port = handle.port
      Port.command(ctx.double, "C")

      # The owner has not handed the E over yet and writes again: the helper
      # is still reading, so the write never meets a closed pipe.
      assert_receive {^port, {:data, "E" <> _code} = gone}, @process_bound
      assert :ok = Serial.write(handle, :binary.copy("late", 1_000))
      refute_receive {^port, {:exit_status, _status}}
      assert Serial.message(handle, {port, gone}) == {:closed, :vanished}
    end

    test "clears RTS before DTR at open, and leaves the lines alone after", ctx do
      cc = System.find_executable("cc")
      assert cc, "cc is needed to build the line recorder"
      source = Path.join(ctx.tmp_dir, "line_recorder.c")
      recorder = Path.join(ctx.tmp_dir, "line_recorder.dylib")
      log = Path.join(ctx.tmp_dir, "lines.log")
      File.write!(source, @line_recorder)

      assert {_output, 0} =
               System.cmd(cc, ["-dynamiclib", source, "-o", recorder], stderr_to_stdout: true)

      env = [
        {~c"DYLD_INSERT_LIBRARIES", String.to_charlist(recorder)},
        {~c"FX_LINE_LOG", String.to_charlist(log)}
      ]

      # The helper runs directly here, not through Serial and the disclaim
      # shim: Serial passes the helper no environment, and the recorder needs
      # two variables.
      port =
        Port.open({:spawn_executable, Serial.helper_path()}, [
          :binary,
          {:packet, 4},
          :exit_status,
          args: ["open", ctx.slave],
          env: env
        ])

      # The recorder answers the line ioctls, so the lines read as cleared.
      assert_receive {^port, {:data, <<"O", 1>>}}, @process_bound
      double = ctx.double
      Port.command(port, "to the device")
      assert_receive {^double, {:data, "R" <> "to the device"}}, @process_bound
      Port.command(double, ["W", "to the host"])
      assert_receive {^port, {:data, "D" <> "to the host"}}, @process_bound
      Port.command(double, "C")
      assert_receive {^port, {:data, "Evanished"}}, @process_bound

      assert File.read!(log) ==
               """
               TIOCEXCL
               tcsetattr ispeed=115200 ospeed=115200
               TIOCMBIC RTS
               tcflush TCIFLUSH
               TIOCMBIC DTR
               """

      Port.close(port)
    end

    test "close ends the helper and releases the port, and closing again is a no-op", ctx do
      assert {:ok, handle} = Serial.open(ctx.slave, open_timeout_ms: @process_bound)
      assert :ok = Serial.close(handle)
      port = handle.port
      refute_received {^port, _message}
      assert Port.info(port) == nil
      assert :ok = Serial.close(handle)
      assert Serial.write(handle, "late") == {:error, :closed}

      # The helper is gone and its lock with it: the port opens again at once.
      assert {:ok, again} = Serial.open(ctx.slave, open_timeout_ms: @process_bound)
      assert :ok = Serial.close(again)
    end

    test "an owner that traps exits is left no exit signal for a closed handle", ctx do
      Process.flag(:trap_exit, true)

      assert {:ok, closed} = Serial.open(ctx.slave, open_timeout_ms: @process_bound)
      assert :ok = Serial.close(closed)
      closed_port = closed.port
      refute_received {:EXIT, ^closed_port, _reason}

      assert {:ok, vanished} = Serial.open(ctx.slave, open_timeout_ms: @process_bound)
      Port.command(ctx.double, "C")
      assert next_transport_message(vanished) == {:closed, :vanished}
      vanished_port = vanished.port
      refute_received {:EXIT, ^vanished_port, _reason}
    end

    test "a tty that stops taking bytes ends the handle as a write stall", ctx do
      assert {:ok, handle} = Serial.open(ctx.slave, open_timeout_ms: @process_bound)
      Port.command(ctx.double, "P")

      assert :ok = Serial.write(handle, :binary.copy(<<0x55>>, 1_048_576))
      assert next_transport_message(handle) == {:closed, :write_stall}
      assert :ok = Serial.close(handle)
    end

    test "a path with nothing there is not found", %{tmp_dir: dir} do
      assert Serial.open(Path.join(dir, "absent-port"), open_timeout_ms: @process_bound) ==
               {:error, :not_found}
    end

    test "a write past the backlog bound is refused", %{tmp_dir: dir} do
      # A helper that answers the open and then never reads its stdin: the
      # bytes back up in the port's queue, with no clock involved.
      assert {:ok, handle} =
               Serial.open(Path.join(dir, "port"),
                 helper_path: answering_stub(dir),
                 open_timeout_ms: @process_bound
               )

      assert :ok = Serial.write(handle, :binary.copy(<<0xAA>>, 1_048_576))
      assert Serial.write(handle, "one more") == {:error, :write_backlog}
      assert :ok = Serial.close(handle)
      assert Port.info(handle.port) == nil
    end

    test "enumerates the attached ports from the registry alone" do
      assert {:ok, ports} = Serial.enumerate(list_timeout_ms: @process_bound)

      for port <- ports do
        assert %{path: "/dev/" <> _, vendor_id: vid, product_id: pid, serial: serial} = port

        assert (is_integer(vid) and vid in 0..65_535 and is_integer(pid)) or
                 {vid, pid} == {nil, nil}

        assert is_binary(serial) or is_nil(serial)
      end
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp port_packet(flags, vid, pid, path, serial) do
    <<"P", flags::8, vid::16, pid::16, byte_size(path)::16, path::binary, byte_size(serial)::16,
      serial::binary>>
  end

  defp all_byte_values(size),
    do:
      0..255
      |> Enum.to_list()
      |> List.duplicate(div(size, 256) + 1)
      |> List.flatten()
      |> :binary.list_to_bin()
      |> binary_part(0, size)

  defp receive_at_double(_double, want, acc) when want <= 0,
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp receive_at_double(double, want, acc) do
    assert_receive {^double, {:data, "R" <> bytes}}, @process_bound
    receive_at_double(double, want - byte_size(bytes), [bytes | acc])
  end

  defp receive_from_helper(_handle, want, acc, reads) when want <= 0,
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), reads}

  defp receive_from_helper(handle, want, acc, reads) do
    assert {:data, bytes} = next_transport_message(handle)
    receive_from_helper(handle, want - byte_size(bytes), [bytes | acc], reads + 1)
  end

  # The next message this handle's transport recognises, as the owner would
  # hand it over.
  defp next_transport_message(handle) do
    assert_receive message, @process_bound

    case Serial.message(handle, message) do
      :unknown -> flunk("a message that is not the transport's: #{inspect(message)}")
      known -> known
    end
  end

  # A stand-in helper that answers an open with lines absent and then sleeps
  # without reading its stdin; close/1 ends it, and its sleep is bounded.
  defp answering_stub(dir) do
    path = Path.join(dir, "answering-helper")
    File.write!(path, "#!/bin/sh\nprintf '\\000\\000\\000\\002O\\000'\nexec sleep 30\n")
    File.chmod!(path, 0o755)
    path
  end
end

defmodule FermixChannels.Accessories.SerialLogTest do
  @moduledoc false
  # Asserts a log line's absence, so it runs alone (AGENTS.md, "Tests under load").
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Accessories.Serial

  @moduletag :tmp_dir

  test "an unavailable transport logs nothing itself and says why in its error", %{tmp_dir: dir} do
    opts = [helper_path: Path.join(dir, "absent-helper"), os_type: {:unix, :darwin}]

    log =
      capture_log(fn ->
        assert {:error, {:unavailable, listed}} = Serial.enumerate(opts)
        assert listed =~ Path.join(dir, "absent-helper")
        assert {:error, {:unavailable, opened}} = Serial.open("/x", opts)
        assert opened =~ "open"
      end)

    refute log =~ "absent-helper"
  end
end
