defmodule FermixChannels.Desktop.ExecutorTest do
  @moduledoc """
  M75 §11: the desktop's runner decides every action under its own policy,
  never the primary's: its executor switch, the deadline, once only, its own
  sandbox for files and commands and its own read grants for files, http(s)
  only for pages, and its own notifications (one shown for every command the
  server runs here). A file goes back as a private staged copy streamed from
  disk. Every decision leaves a receipt of hashes.

  The sandbox config, the notification backend, the opener's platform and the
  command runner are this test's, handed in the context; nothing global is
  read or changed, and no page is ever opened.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Executor
  alias FermixChannels.Desktop.Receipts
  alias FermixCore.Home.ReadGrants
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy
  alias FermixTestSupport.SafeRm

  @now 1_000_000

  setup do
    home = SafeRm.make_tmp_dir!("desktop-executor")
    workspace = Path.join(home, "workspace")
    File.mkdir_p!(workspace)
    receipts = start_supervised!({Receipts, home: home, name: nil})
    staging = Path.join([home, "device", "media-send"])
    File.mkdir_p!(staging)
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    test_pid = self()

    context = %{
      receipts: receipts,
      received_at_ms: @now,
      now_ms: fn -> @now end,
      utc_now: fn -> ~U[2026-10-27 09:30:00Z] end,
      max_media_bytes: 64 * 1_024,
      send_staging: staging,
      home: home,
      primary_name: "fermix-vm",
      engine: [role: :device],
      sandbox_config: Config.normalize(mode: :strict, workspace_root: workspace),
      notifications: dbus(test_pid),
      run: fn executable, args, opts ->
        send(test_pid, {:ran, executable, args, opts})
        {:ok, %{exit: 0, stdout: "", truncated?: false}}
      end
    }

    %{home: home, workspace: workspace, receipts: receipts, context: context}
  end

  # This engine's notifications over a stand-in D-Bus, reporting to the test:
  # no notification is ever shown on the machine the suite runs on.
  defp dbus(test_pid) do
    runner = fn _busctl, args ->
      send(test_pid, {:busctl, args})
      if "NameHasOwner" in args, do: {:ok, "b true"}, else: {:ok, "u 7"}
    end

    [provider: :dbus, find_executable: fn "busctl" -> "/usr/bin/busctl" end, runner: runner]
  end

  defp invoke(action, n \\ System.unique_integer([:positive]), deadline_s \\ 30),
    do: %{"invocation_id" => "inv-#{n}", "action" => action, "deadline_s" => deadline_s}

  defp args(map, correlation \\ "sess-42"),
    do: map |> Map.put("correlation_id", correlation) |> Jason.encode!()

  describe "before anything runs" do
    test "nothing runs while this computer's executor switch is off", ctx do
      context = %{ctx.context | engine: [role: :device, executor: false]}

      assert {:refused, %{"reason" => "executor_off"} = result, nil} =
               Executor.handle(invoke("open_url"), args(%{"url" => "https://a.test/"}), context)

      assert result["correlation_id"] == "sess-42"
      refute_received {:ran, _executable, _args, _opts}
    end

    test "an invocation past its deadline is refused without running", ctx do
      late = %{ctx.context | now_ms: fn -> @now + 30_000 end}

      assert {:refused, %{"reason" => "deadline_passed"}, nil} =
               Executor.handle(invoke("open_url"), args(%{"url" => "https://a.test/"}), late)

      refute_received {:ran, _executable, _args, _opts}
    end

    test "an invocation already handled here is never run twice", ctx do
      fields = invoke("open_url", 7)
      context = Map.merge(ctx.context, %{os_type: {:unix, :darwin}, shim_path: "/opt/disclaim"})

      assert {:ok, _result, nil} =
               Executor.handle(fields, args(%{"url" => "https://a.test/"}), context)

      assert_received {:ran, _executable, _args, _opts}

      assert {:refused, %{"reason" => "already_handled", "message" => message}, nil} =
               Executor.handle(fields, args(%{"url" => "https://a.test/"}), context)

      assert message =~ "ok at 2026-10-27T09:30:00Z"
      refute_received {:ran, _executable, _args, _opts}
    end

    test "an unknown action and arguments that are not an object are refused", ctx do
      assert {:refused, %{"reason" => "unknown_action"}, nil} =
               Executor.handle(invoke("format_disk"), args(%{}), ctx.context)

      assert {:refused, %{"reason" => "invalid_arguments", "correlation_id" => "none"}, nil} =
               Executor.handle(invoke("notify"), "[1,2]", ctx.context)

      assert {:refused, %{"reason" => "invalid_arguments"}, nil} =
               Executor.handle(invoke("notify"), args(%{"title" => ""}), ctx.context)
    end
  end

  describe "files" do
    test "Fermix's token file, secrets, identity and device folder are never read, whatever the primary asks",
         ctx do
      fermix_home = System.fetch_env!("FERMIX_HOME")
      # Even a sandbox whose roots cover the whole home keeps them private.
      wide = %{
        ctx.context
        | sandbox_config:
            Config.normalize(
              mode: :strict,
              workspace_root: ctx.workspace,
              allowed_roots: [fermix_home]
            )
      }

      for private <- [
            "auth.json",
            "secrets/openai_api_key",
            "mobile/gateway_key",
            "device/desktop_key",
            "device/receipts.jsonl"
          ] do
        path = Path.join(fermix_home, private)

        assert {:refused, %{"reason" => "protected_path", "message" => message}, nil} =
                 Executor.handle(invoke("read_file"), args(%{"path" => path}), wide)

        assert message =~ "keeps private on this computer"
      end
    end

    test "a file outside this computer's sandbox is refused, naming where to allow it", ctx do
      outside = SafeRm.make_tmp_dir!("desktop-executor-outside")
      on_exit(fn -> SafeRm.rm_rf!(outside) end)
      File.write!(Path.join(outside, "plan.txt"), "secret plan")

      assert {:refused, %{"reason" => "outside_sandbox", "message" => message}, nil} =
               Executor.handle(
                 invoke("read_file"),
                 args(%{"path" => Path.join(outside, "plan.txt")}),
                 ctx.context
               )

      assert message =~ "ask for read access to its folder (grant_read)"
    end

    test "a file inside it comes back as a private copy streamed from disk, described by hash",
         ctx do
      path = Path.join(ctx.workspace, "lease.pdf")
      File.write!(path, "%PDF-1.7 lease")

      assert {:ok, result, {:file, staged, 14}} =
               Executor.handle(invoke("read_file", 31), args(%{"path" => path}), ctx.context)

      assert staged == Path.join(ctx.context.send_staging, "inv-31")
      assert File.read!(staged) == "%PDF-1.7 lease"
      assert File.stat!(staged).mode |> Bitwise.band(0o777) == 0o600
      assert result["name"] == "lease.pdf"
      assert result["size_bytes"] == 14

      assert result["sha256"] ==
               Base.encode16(:crypto.hash(:sha256, "%PDF-1.7 lease"), case: :lower)

      assert result["correlation_id"] == "sess-42"
    end

    test "a file over the session's media bound is refused", ctx do
      path = Path.join(ctx.workspace, "big.bin")
      File.write!(path, :binary.copy("x", 64 * 1_024 + 1))

      assert {:refused, %{"reason" => "too_large"}, nil} =
               Executor.handle(invoke("read_file"), args(%{"path" => path}), ctx.context)
    end

    test "a folder lists at most 500 entries, sorted, without following links", ctx do
      folder = Path.join(ctx.workspace, "many")
      File.mkdir_p!(Path.join(folder, "a-sub"))

      for n <- 1..505,
          do: File.write!(Path.join(folder, "f#{String.pad_leading("#{n}", 3, "0")}"), "x")

      assert {:ok, result, nil} =
               Executor.handle(invoke("list_directory"), args(%{"path" => folder}), ctx.context)

      assert result["total"] == 506
      assert result["truncated"] == true
      assert length(result["entries"]) == 500
      assert hd(result["entries"]) == %{"name" => "a-sub", "type" => "directory"}

      assert Enum.at(result["entries"], 1) == %{
               "name" => "f001",
               "type" => "file",
               "size_bytes" => 1
             }
    end
  end

  describe "read grants" do
    setup do
      outside = SafeRm.make_tmp_dir!("desktop-executor-granted")
      on_exit(fn -> SafeRm.rm_rf!(outside) end)
      File.write!(Path.join(outside, "plan.txt"), "the plan")
      %{outside: outside, canonical: PathPolicy.canonical_path(outside)}
    end

    test "a granted folder is recorded in this computer's own grants, and read there", ctx do
      file = Path.join(ctx.outside, "plan.txt")

      assert {:refused, %{"reason" => "outside_sandbox"}, nil} =
               Executor.handle(invoke("read_file"), args(%{"path" => file}), ctx.context)

      assert {:ok, %{"path" => granted}, nil} =
               Executor.handle(invoke("grant_read"), args(%{"path" => ctx.outside}), ctx.context)

      assert granted == ctx.canonical
      assert {:ok, [ctx.canonical]} == ReadGrants.folders(ctx.home)
      assert File.stat!(ReadGrants.path(ctx.home)).mode |> Bitwise.band(0o777) == 0o600

      assert {:ok, %{"name" => "plan.txt"}, {:file, _staged, 8}} =
               Executor.handle(invoke("read_file"), args(%{"path" => file}), ctx.context)

      assert {:ok, %{"entries" => entries}, nil} =
               Executor.handle(
                 invoke("list_directory"),
                 args(%{"path" => ctx.outside}),
                 ctx.context
               )

      assert %{"name" => "plan.txt", "type" => "file", "size_bytes" => 8} in entries
    end

    test "a grant is shown on this computer the moment it is recorded, naming the folder and the server",
         ctx do
      assert {:ok, %{"path" => granted}, nil} =
               Executor.handle(invoke("grant_read"), args(%{"path" => ctx.outside}), ctx.context)

      assert_received {:busctl, _owner_args}
      assert_received {:busctl, notify_args}
      assert "Fermix on fermix-vm can now read a folder here" in notify_args

      assert "#{granted}. If you did not allow this, remove it in Fermix on this computer." in notify_args

      # A grant refused is recorded nowhere and shown nowhere.
      assert {:refused, %{"reason" => "unsafe_root"}, nil} =
               Executor.handle(invoke("grant_read"), args(%{"path" => "/"}), ctx.context)

      refute_received {:busctl, _args}
    end

    test "a grant the owner removed no longer widens the next read", ctx do
      file = Path.join(ctx.outside, "plan.txt")

      {:ok, %{"path" => granted}, nil} =
        Executor.handle(invoke("grant_read"), args(%{"path" => ctx.outside}), ctx.context)

      assert {:ok, _result, {:file, _staged, 8}} =
               Executor.handle(invoke("read_file"), args(%{"path" => file}), ctx.context)

      assert {:ok, []} = ReadGrants.remove(ctx.home, [granted])

      assert {:refused, %{"reason" => "outside_sandbox"}, nil} =
               Executor.handle(invoke("read_file"), args(%{"path" => file}), ctx.context)

      assert {:refused, %{"reason" => "outside_sandbox"}, nil} =
               Executor.handle(
                 invoke("list_directory"),
                 args(%{"path" => ctx.outside}),
                 ctx.context
               )
    end

    test "a grant reads and nothing more: no command runs in a granted folder", ctx do
      {:ok, _result, nil} =
        Executor.handle(invoke("grant_read"), args(%{"path" => ctx.outside}), ctx.context)

      assert {:refused, %{"reason" => "outside_sandbox"}, nil} =
               Executor.handle(
                 invoke("run_command"),
                 args(%{"command" => "ls", "cwd" => ctx.outside}),
                 ctx.context
               )
    end

    test "the whole disk, the home folder, Fermix's home, a file or a relative path is never granted",
         ctx do
      fermix_home = System.fetch_env!("FERMIX_HOME")

      for path <- ["/", System.user_home!(), fermix_home] do
        assert {:refused, %{"reason" => "unsafe_root"}, nil} =
                 Executor.handle(invoke("grant_read"), args(%{"path" => path}), ctx.context)
      end

      assert {:refused, %{"reason" => "not_a_folder"}, nil} =
               Executor.handle(
                 invoke("grant_read"),
                 args(%{"path" => Path.join(ctx.outside, "plan.txt")}),
                 ctx.context
               )

      assert {:refused, %{"reason" => "invalid_arguments"}, nil} =
               Executor.handle(invoke("grant_read"), args(%{"path" => "Downloads"}), ctx.context)

      assert {:ok, []} == ReadGrants.folders(ctx.home)
    end

    test "a protected path inside a granted folder stays closed", ctx do
      fermix_home = System.fetch_env!("FERMIX_HOME")
      parent = Path.dirname(fermix_home)
      :ok = ReadGrants.add(ctx.home, parent, ~U[2026-10-27 09:00:00Z])

      assert {:refused, %{"reason" => "protected_path"}, nil} =
               Executor.handle(
                 invoke("read_file"),
                 args(%{"path" => Path.join(fermix_home, "auth.json")}),
                 ctx.context
               )
    end
  end

  describe "commands" do
    test "this computer shows a notification as the server runs a command here", ctx do
      assert {:ok, _result, nil} =
               Executor.handle(invoke("run_command"), args(%{"command" => "df -h"}), ctx.context)

      assert_received {:busctl, _owner_args}
      assert_received {:busctl, notify_args}
      assert "Fermix on fermix-vm is running a command here" in notify_args
      assert "df -h" in notify_args
      assert_received {:ran, _sh, _args, _opts}
    end

    test "run through this computer's confined shell, with output cut at 64 KiB", ctx do
      context = Map.delete(ctx.context, :run)

      assert {:ok, %{"exit_code" => 0, "output" => "hello", "truncated" => false}, nil} =
               Executor.handle(
                 invoke("run_command"),
                 args(%{"command" => "printf hello", "cwd" => ctx.workspace}),
                 context
               )

      assert {:failed, %{"reason" => "output_too_long", "output" => output}, nil} =
               Executor.handle(
                 invoke("run_command"),
                 args(%{"command" => "yes a | head -c 70000"}),
                 context
               )

      assert byte_size(output) <= 64 * 1_024
      assert output =~ ~r/\A(a\n)+a?\z/
    end

    test "a failing command is failed with its exit code and output", ctx do
      context = Map.delete(ctx.context, :run)

      assert {:failed, %{"exit_code" => 3, "output" => "nope", "reason" => "exit_nonzero"}, nil} =
               Executor.handle(
                 invoke("run_command"),
                 args(%{"command" => "printf nope; exit 3"}),
                 context
               )
    end

    test "its own sandbox refuses a folder outside it and a catastrophic command", ctx do
      outside = SafeRm.make_tmp_dir!("desktop-executor-cwd")
      on_exit(fn -> SafeRm.rm_rf!(outside) end)

      assert {:refused, %{"reason" => "outside_sandbox"}, nil} =
               Executor.handle(
                 invoke("run_command"),
                 args(%{"command" => "ls", "cwd" => outside}),
                 ctx.context
               )

      assert {:refused, %{"reason" => "hardline"}, nil} =
               Executor.handle(
                 invoke("run_command"),
                 args(%{"command" => "rm -rf /"}),
                 ctx.context
               )

      refute_received {:ran, _executable, _args, _opts}
    end

    test "its run is bounded by what is left of the deadline", ctx do
      context = %{ctx.context | now_ms: fn -> @now + 10_000 end}

      assert {:ok, _result, nil} =
               Executor.handle(invoke("run_command"), args(%{"command" => "true"}), context)

      assert_received {:ran, _sh, _args, opts}
      assert opts[:timeout_ms] == 15_000
      assert opts[:max_output_bytes] == 64 * 1_024
    end
  end

  describe "pages and notifications" do
    test "only an http or https page is opened", ctx do
      context = Map.merge(ctx.context, %{os_type: {:unix, :darwin}, shim_path: "/opt/disclaim"})

      for url <- ["javascript:alert(1)", "file:///etc/hosts", "https://", "http://a b.test/"] do
        assert {:refused, %{"reason" => "not_a_web_url"}, nil} =
                 Executor.handle(invoke("open_url"), args(%{"url" => url}), context)
      end

      refute_received {:ran, _executable, _args, _opts}
    end

    test "on a Mac the opener is spawned through the disclaim shim, never without it", ctx do
      mac = Map.merge(ctx.context, %{os_type: {:unix, :darwin}, shim_path: "/opt/disclaim"})

      assert {:ok, %{"url" => "https://fermix.test/docs"}, nil} =
               Executor.handle(
                 invoke("open_url"),
                 args(%{"url" => "https://fermix.test/docs"}),
                 mac
               )

      assert_received {:ran, "/opt/disclaim", ["/usr/bin/open", "https://fermix.test/docs"],
                       _opts}

      no_shim = %{mac | shim_path: nil}

      assert {:refused, %{"reason" => "no_opener", "message" => message}, nil} =
               Executor.handle(
                 invoke("open_url"),
                 args(%{"url" => "https://fermix.test/"}),
                 no_shim
               )

      assert message =~ "disclaim shim"
      refute_received {:ran, _executable, _args, _opts}
    end

    test "on Linux the opener is xdg-open, and its absence is named", ctx do
      linux =
        Map.merge(ctx.context, %{
          os_type: {:unix, :linux},
          find_executable: fn "xdg-open" -> "/usr/bin/xdg-open" end
        })

      assert {:ok, _result, nil} =
               Executor.handle(
                 invoke("open_url"),
                 args(%{"url" => "http://intranet.test/"}),
                 linux
               )

      assert_received {:ran, "/usr/bin/xdg-open", ["http://intranet.test/"], _opts}

      bare = %{linux | find_executable: fn "xdg-open" -> nil end}

      assert {:refused, %{"reason" => "no_opener", "message" => "xdg-open is not installed" <> _},
              nil} = Executor.handle(invoke("open_url"), args(%{"url" => "http://a.test/"}), bare)
    end

    test "a notification goes through this engine's own notifications", ctx do
      test_pid = self()

      runner = fn _busctl, args ->
        send(test_pid, {:busctl, args})
        if "NameHasOwner" in args, do: {:ok, "b true"}, else: {:ok, "u 7"}
      end

      dbus = [
        provider: :dbus,
        find_executable: fn "busctl" -> "/usr/bin/busctl" end,
        runner: runner
      ]

      context = Map.put(ctx.context, :notifications, dbus)

      assert {:ok, _result, nil} =
               Executor.handle(
                 invoke("notify"),
                 args(%{"title" => "Kettle", "body" => "The tea is ready."}),
                 context
               )

      assert_received {:busctl, owner_args}
      assert "NameHasOwner" in owner_args
      assert_received {:busctl, notify_args}
      assert "The tea is ready." in notify_args
    end

    test "a build that shows no notifications refuses by name", ctx do
      context =
        Map.put(ctx.context, :notifications,
          provider: :none,
          host: %{profile: :standalone_cli, os: :darwin}
        )

      assert {:refused, %{"reason" => "not_offered", "message" => message}, nil} =
               Executor.handle(invoke("notify"), args(%{"title" => "a", "body" => "b"}), context)

      assert message =~ "shows no notifications on this Mac"
    end
  end

  describe "receipts and the answer" do
    test "every decision leaves a receipt of hashes, never the arguments or the output", ctx do
      path = Path.join(ctx.workspace, "notes.txt")
      File.write!(path, "pay the gas bill")
      payload = args(%{"path" => path})

      {:ok, result, _bytes} = Executor.handle(invoke("read_file", 1), payload, ctx.context)

      {:refused, _refusal, nil} =
        Executor.handle(invoke("format_disk", 2), args(%{}), ctx.context)

      contents = File.read!(Receipts.path(ctx.home))
      refute contents =~ "pay the gas bill"
      refute contents =~ "notes.txt"

      assert [first, second] =
               contents |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert first == %{
               "invocation_id" => "inv-1",
               "action" => "read_file",
               "status" => "ok",
               "finished_at" => "2026-10-27T09:30:00Z",
               "args_sha256" => sha(payload),
               "result_sha256" => sha(Jason.encode!(result))
             }

      assert second["status"] == "refused"

      assert Executor.receipts(ctx.receipts, ["inv-2", "inv-404", "inv-1"]) == [
               %{
                 "invocation_id" => "inv-2",
                 "status" => "refused",
                 "finished_at" => "2026-10-27T09:30:00Z"
               },
               %{
                 "invocation_id" => "inv-1",
                 "status" => "ok",
                 "finished_at" => "2026-10-27T09:30:00Z"
               }
             ]
    end

    test "a file's bytes go back before its result" do
      assert [
               {"invoke_blob", %{"invocation_id" => "inv-9"}, {:file, "/staged/inv-9", 5}},
               {"invoke_result", %{"invocation_id" => "inv-9", "status" => "ok"}, json}
             ] =
               Executor.answer("inv-9", {:ok, %{"name" => "a.txt"}, {:file, "/staged/inv-9", 5}})

      assert Jason.decode!(json) == %{"name" => "a.txt"}

      assert [{"invoke_result", %{"status" => "refused"}, _json}] =
               Executor.answer("inv-9", {:refused, %{"reason" => "x"}, nil})
    end
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
