defmodule FermixCore.Computers.CapabilitiesTest do
  # M97 §6.4: on the computer, files and shell run the tools' own code under
  # that computer's sandbox, which the invocation's context carries; never the
  # application environment of the engine the test VM runs. Each test is its
  # own computer home under a temporary folder. async: false: a command records
  # the environment's health in a VM-wide table.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Computers.Capabilities.Files
  alias FermixCore.Computers.Capabilities.Local
  alias FermixCore.Computers.Capabilities.Shell
  alias FermixCore.Computers.ToolResult
  alias FermixCore.Sandbox.Config
  alias FermixTestSupport.SafeRm

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy("p", 64)

  setup do
    root = SafeRm.make_tmp_dir!("computer_capability")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    %{root: root, workspace: workspace}
  end

  # The invocation's context as Admission builds it, with this computer's own
  # sandbox: strict, its workspace the only root, its home the temporary one.
  defp context(root, more \\ []) do
    sandbox =
      [mode: :strict, home: root, os_home: root, workspace_root: Path.join(root, "workspace")]
      |> Keyword.merge(more)
      |> Config.normalize()

    %{id: "inv-#{System.unique_integer([:positive])}", origin: :chat, sandbox: sandbox}
  end

  # A tool that ran and succeeded: the invocation is ok, with its result.
  defp ran(module, op, args, ctx, part \\ nil) do
    assert :ok = module.admit(op, args, ctx)
    assert {:ok, json, part_out} = module.run(op, args, part, ctx)

    assert {:ok, %{success: true} = result} =
             json |> Jason.encode!() |> Jason.decode!() |> ToolResult.decode(part_out)

    {result, json, part_out}
  end

  # A tool that ran and failed: the invocation fails with the error's first
  # line, and the tool's whole result still rides the answer and its part, so
  # the computer's journal and the server's exec event tell it from a success.
  defp failed(module, op, args, ctx, part \\ nil) do
    assert :ok = module.admit(op, args, ctx)
    assert {:failed, message, json, part_out} = module.run(op, args, part, ctx)

    assert {:ok, %{success: false} = result} =
             json |> Jason.encode!() |> Jason.decode!() |> ToolResult.decode(part_out)

    assert message == first_said(result.error)
    {result, message, part_out}
  end

  defp first_said(text),
    do: text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))

  test "a failure's message is the first line of its error that says something" do
    assert {:failed, "Path is protected.", %{"success" => false, "error" => error}, nil} =
             Local.ran({:ok, Tool.error("\n  Path is protected.  \nmore")})

    assert error == "\n  Path is protected.  \nmore"
    assert {:ok, %{"success" => true}, nil} = Local.ran({:ok, Tool.success("done")})
  end

  describe "files" do
    test "reads a file inside the computer's roots", %{root: root, workspace: ws} do
      File.write!(Path.join(ws, "notes.txt"), "plant tomatoes\nwater beans")

      {result, _json, nil} =
        ran(Files, "file.read", %{"path" => Path.join(ws, "notes.txt")}, context(root))

      assert result == %{success: true, output: "plant tomatoes\nwater beans", error: nil}
    end

    test "a read stops at the tool's own 100 KB", %{root: root, workspace: ws} do
      line = String.duplicate("x", 99) <> "\n"
      File.write!(Path.join(ws, "long.txt"), String.duplicate(line, 1_500))

      {result, _json, _part} =
        ran(Files, "file.read", %{"path" => Path.join(ws, "long.txt")}, context(root))

      assert result.output =~ "[truncated at 100000 bytes — continue with offset 1001]"
    end

    test "a path outside the computer's roots is refused before anything runs", %{root: root} do
      outside = Path.join(root, "private")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "diary.txt"), "dear diary")

      assert {:refused, :outside_sandbox, sentence} =
               Files.admit(
                 "file.read",
                 %{"path" => Path.join(outside, "diary.txt")},
                 context(root)
               )

      assert sentence =~ "diary.txt is outside this computer's sandbox."
    end

    test "the same path is inside an open sandbox", %{root: root} do
      File.mkdir_p!(Path.join(root, "private"))
      File.write!(Path.join(root, "private/diary.txt"), "dear diary")
      ctx = context(root, mode: :open)

      {result, _json, nil} =
        ran(Files, "file.read", %{"path" => Path.join(root, "private/diary.txt")}, ctx)

      assert result.output == "dear diary"
    end

    test "the computer's own settings and secrets stay refused, in the tool's words",
         %{root: root} do
      File.write!(
        Path.join(root, "machine.toml"),
        "[fermix_core.computer]\nfiles_and_shell = true\n"
      )

      File.mkdir_p!(Path.join(root, "secrets"))
      ctx = context(root, mode: :open)

      for path <- ["machine.toml", "config.toml", "secrets/token", "device/desktop.json"] do
        {result, message, nil} =
          failed(Files, "file.read", %{"path" => Path.join(root, path)}, ctx)

        assert result.error =~ "Path is protected by the sandbox", path
        assert message =~ "Path is protected by the sandbox", path
      end

      {write, _message, nil} =
        failed(
          Files,
          "file.write",
          %{"path" => Path.join(root, "machine.toml"), "content" => "x"},
          ctx
        )

      assert write.error =~ "Sandbox denied protected path"
      assert File.read!(Path.join(root, "machine.toml")) =~ "files_and_shell = true"
    end

    test "writes, edits, globs and searches inside the roots", %{root: root, workspace: ws} do
      ctx = context(root)
      path = Path.join(ws, "plan.md")

      {written, _json, nil} =
        ran(Files, "file.write", %{"path" => path, "content" => "# Plan\nbuy seeds"}, ctx)

      assert written.output =~ "Wrote 16 bytes"

      {edited, _json, nil} =
        ran(
          Files,
          "file.edit",
          %{"path" => path, "old_string" => "buy", "new_string" => "sow"},
          ctx
        )

      assert edited.success
      assert File.read!(path) == "# Plan\nsow seeds"

      {globbed, _json, nil} = ran(Files, "file.glob", %{"path" => ws, "pattern" => "*.md"}, ctx)
      assert [found] = Jason.decode!(globbed.output)
      assert found =~ "plan.md"

      {searched, _json, nil} =
        ran(Files, "file.search", %{"path" => ws, "pattern" => "seeds"}, ctx)

      assert %{"matches" => [%{"line" => 2, "text" => "sow seeds"}]} =
               Jason.decode!(searched.output)
    end

    test "content too large for the request rides its part", %{root: root, workspace: ws} do
      content = :binary.copy("z", 300 * 1_024)
      path = Path.join(ws, "big.txt")
      args = Files.without_content(%{"path" => path, "content" => content})

      assert :ok = Files.validate("file.write", args)
      {written, _json, nil} = ran(Files, "file.write", args, context(root), content)

      assert written.success
      assert File.read!(path) == content
      assert {:failed, _sentence} = Files.run("file.write", args, nil, context(root))
    end

    test "an image rides the part; one over 10 MiB is refused by the tool", %{
      root: root,
      workspace: ws
    } do
      File.write!(Path.join(ws, "leaf.png"), @png)
      File.write!(Path.join(ws, "huge.png"), @png <> :binary.copy("p", 10 * 1_024 * 1_024))
      ctx = context(root)

      {seen, json, part} =
        ran(Files, "image.view", %{"paths" => [Path.join(ws, "leaf.png")]}, ctx)

      assert part == @png
      assert [%{"mime_type" => "image/png", "bytes" => 72}] = json["images"]
      assert [%{type: :image, data: @png}] = seen.images

      {huge, _message, nil} =
        failed(Files, "image.view", %{"paths" => [Path.join(ws, "huge.png")]}, ctx)

      assert huge.error =~ "the per-file limit is 10485760 bytes"
    end

    test "a file to send comes back as bytes, named and kinded", %{root: root, workspace: ws} do
      bytes = :crypto.strong_rand_bytes(4_096)
      File.write!(Path.join(ws, "report.pdf"), bytes)
      args = %{"path" => Path.join(ws, "report.pdf"), "caption" => "The report"}

      assert :ok = Files.admit("file.send", args, context(root))
      assert {:ok, read, ^bytes} = Files.run("file.send", args, nil, context(root))

      assert read == %{
               "success" => true,
               "filename" => "report.pdf",
               "kind" => "document",
               "caption" => "The report"
             }

      File.write!(Path.join(ws, "empty.txt"), "")

      assert {:failed, "The file is empty, so there is nothing to send.",
              %{"success" => false, "error" => "The file is empty, so there is nothing to send."},
              nil} =
               Files.run("file.send", %{"path" => Path.join(ws, "empty.txt")}, nil, context(root))
    end

    test "only writes and edits change something; a read, a look and a send are read again" do
      assert Enum.filter(Files.ops(), &Files.effect?/1) == ["file.edit", "file.write"]

      assert Files.target("file.read", %{"path" => "/Users/pat/notes.txt"}) ==
               "/Users/pat/notes.txt"

      assert Files.target("image.view", %{"paths" => ["a.png", "b.png"]}) == "a.png, b.png"
      assert Files.deadline_ms("file.search", %{"timeout_ms" => 60_000}) == 65_000
    end
  end

  describe "shell" do
    test "runs a command under the computer's sandbox", %{root: root, workspace: ws} do
      {result, _json, nil} =
        ran(Shell, "shell.run", %{"command" => "pwd", "working_dir" => ws}, context(root))

      assert result.success
      assert result.output =~ "workspace"
    end

    test "a folder outside the computer's roots is refused before anything runs", %{root: root} do
      assert {:refused, :outside_sandbox, sentence} =
               Shell.admit(
                 "shell.run",
                 %{"command" => "ls", "working_dir" => root},
                 context(root)
               )

      assert sentence =~ "is outside this computer's sandbox."
    end

    test "output above 256 KiB rides the part, and 1 MiB is the most", %{
      root: root,
      workspace: ws
    } do
      ctx = context(root)

      {big, json, part} =
        ran(
          Shell,
          "shell.run",
          %{"command" => "head -c 300000 /dev/zero | tr '\\0' a", "working_dir" => ws},
          ctx
        )

      assert json["text_part"] == "output"
      assert byte_size(part) == 300_000
      assert big.output == part

      {most, message, part} =
        failed(
          Shell,
          "shell.run",
          %{"command" => "head -c 1200000 /dev/zero | tr '\\0' b", "working_dir" => ws},
          ctx
        )

      # Past 1 MiB the command is stopped, as it is here: the tool says so, with
      # what it wrote up to 1 MiB, which rides the part. How much below 1 MiB
      # depends on how the pipe's reads fell (`CommandRunner` keeps what came
      # before the read that crossed it), so only the bound is pinned.
      assert "Command failed (exit code 124):\n" <> kept = most.error
      assert byte_size(kept) in (ToolResult.inline_bytes() + 1)..1_048_576
      assert kept == :binary.copy("b", byte_size(kept))
      assert message == "Command failed (exit code 124):"
      assert part == most.error
      assert byte_size(part) <= Shell.bounds("shell.run").part_bytes
    end

    test "a command that fails is a failed invocation that keeps its whole output",
         %{root: root, workspace: ws} do
      {result, message, nil} =
        failed(
          Shell,
          "shell.run",
          %{"command" => "echo almost; exit 3", "working_dir" => ws},
          context(root)
        )

      assert message == "Command failed (exit code 3):"
      assert result.error == "Command failed (exit code 3):\nalmost\n"
    end

    test "a command and a git write change something; a git read does not" do
      assert Shell.effect?("shell.run")
      assert Shell.effect?("git.write")
      refute Shell.effect?("git.read")
    end

    test "the journal names a command by its first words, never what it carries" do
      assert Shell.target("shell.run", %{"command" => "git status --short"}) == "git status"
      assert Shell.target("shell.run", %{"command" => "TOKEN=abc123 make release"}) == "a command"
      assert Shell.target("shell.run", %{"command" => "curl -H 'Authorization: x'"}) == "curl"

      assert Shell.target("git.write", %{"command" => "commit", "repo" => "/srv/site"}) ==
               "git commit /srv/site"
    end

    test "a command's deadline is its own timeout and the time its sandbox takes" do
      assert Shell.deadline_ms("shell.run", %{}) == 40_000
      assert Shell.deadline_ms("shell.run", %{"timeout_ms" => 120_000}) == 130_000
      assert {:error, _sentence} = Shell.validate("shell.run", %{"timeout_ms" => 899_000})
    end
  end
end
