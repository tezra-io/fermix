defmodule FermixCore.Checklists.NoteTest do
  # MILESTONE_85 §05, §12: the index note names the owner's lists by folder,
  # names only, is absent with none and unchanged by a tick, and stays inside
  # its budget with ten lists; the two tool schemas stay inside theirs; a read
  # or an edit that shows a framed row taints the turn, and each emits its
  # event with no owner words.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Checklists.Note
  alias FermixCore.Checklists.Registry
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Tools.ChecklistEdit
  alias FermixCore.Tools.ChecklistRead
  alias FermixTestSupport.TelemetryCapture

  @owner %{
    agent_name: "main",
    conversation_key: {"telegram", "40051", :root},
    source_trust: :operator,
    computer_use_origin: :interactive,
    chat_type: "private",
    outside_sources: MapSet.new()
  }

  # Ten lists as the owner might keep them; every name is invented.
  @ten [
    {"Fermix", "Projects"},
    {"Portfolio site", "Projects"},
    {"OBAI", "Projects"},
    {"OpenBell", "Projects"},
    {"Fermix Android", "Projects"},
    {"Garden", "Home"},
    {"Kitchen repairs", "Home"},
    {"Groceries", nil},
    {"Hardware store", nil},
    {"Books to read", nil}
  ]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-checklist-note-#{unique}.db")
    repo = :"checklist_note_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    holder = start_supervised!({ReplyBlocks, name: nil})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, context: Map.merge(@owner, %{memory_repo: repo, reply_blocks: holder})}
  end

  defp create_ten!(repo) do
    @ten
    |> Enum.map(fn {title, folder} ->
      %{"list" => title, "ops" => [%{"op" => "create", "folder" => folder}]}
    end)
    |> Enum.chunk_every(Registry.max_changes())
    |> Enum.each(fn changes ->
      {:ok, _} = Registry.edit(%{"changes" => changes}, @owner, repo: repo)
    end)
  end

  test "with no list there is no note", %{context: context} do
    assert Note.index(context) == nil
  end

  test "ten lists: names by folder in picker order, the loose ones last, inside the budget", %{
    repo: repo,
    context: context
  } do
    create_ten!(repo)
    note = Note.index(context)

    assert note ==
             ~s(The owner's lists: in "Projects", "Fermix", "Portfolio site", "OBAI", "OpenBell", ) <>
               ~s("Fermix Android"; in "Home", "Garden", "Kitchen repairs"; "Groceries", ) <>
               ~s("Hardware store", "Books to read".)

    # §12 budgets the note at 60 tokens with ten lists: measured at 56 with
    # o200k_base for this line; 4 characters a token bounds it in bytes here.
    assert byte_size(note) <= 240
  end

  test "a tick, an add and a reword leave the note as it was; a rename changes it", %{
    repo: repo,
    context: context
  } do
    create_ten!(repo)
    before = Note.index(context)

    ops = [%{"op" => "add", "text" => "Lemons"}, %{"op" => "check", "n" => 1}]

    {:ok, _} =
      Registry.edit(%{"changes" => [%{"list" => "Groceries", "ops" => ops}]}, @owner, repo: repo)

    assert Note.index(context) == before

    rename = [%{"list" => "Groceries", "ops" => [%{"op" => "rename", "text" => "Shopping"}]}]
    {:ok, _} = Registry.edit(%{"changes" => rename}, @owner, repo: repo)
    assert Note.index(context) =~ ~s("Shopping")
  end

  test "the two tool schemas stay inside the 500-token budget" do
    encoded =
      [ChecklistRead, ChecklistEdit]
      |> Enum.map(&%{name: &1.name(), description: &1.description(), parameters: &1.parameters()})
      |> Jason.encode!()

    # Measured at 482 tokens with o200k_base (M85 §12); 2,000 bytes is the
    # bound that keeps it under 500 at this schema's four bytes a token.
    assert byte_size(encoded) <= 2_000
  end

  test "a read that shows a row added after outside content taints the turn; a clean one does not",
       %{repo: repo, context: context} do
    changes = [
      %{
        "list" => "Groceries",
        "ops" => [%{"op" => "create"}, %{"op" => "add", "text" => "Lemons"}]
      }
    ]

    {:ok, _} = Registry.edit(%{"changes" => changes}, @owner, repo: repo)

    read = Builtin.from_tool_module(ChecklistRead)
    {:ok, clean} = ChecklistRead.execute(%{"list" => "Groceries"}, context)
    assert UntrustedContent.outside_source(read, %{}, clean.output) == nil

    tainted = %{context | outside_sources: MapSet.new([{:tool, "web_fetch"}])}
    add = [%{"list" => "Groceries", "ops" => [%{"op" => "add", "text" => "Rice"}]}]
    {:ok, answer} = ChecklistEdit.execute(%{"changes" => add}, tainted)

    edit = Builtin.from_tool_module(ChecklistEdit)

    assert UntrustedContent.outside_source(edit, %{}, answer.output) ==
             UntrustedContent.checklist_source()

    {:ok, framed} = ChecklistRead.execute(%{"list" => "Groceries"}, context)

    assert UntrustedContent.outside_source(read, %{}, framed.output) ==
             UntrustedContent.checklist_source()
  end

  test "the tools record each list they touched for the reply's block", %{context: context} do
    create = [
      %{
        "list" => "Groceries",
        "ops" => [%{"op" => "create"}, %{"op" => "add", "text" => "Lemons"}]
      }
    ]

    {:ok, %{success: true}} = ChecklistEdit.execute(%{"changes" => create}, context)
    {:ok, %{success: true}} = ChecklistRead.execute(%{"list" => "Groceries"}, context)

    assert [
             {:checklist, %{list_id: "ck_" <> _ = id, title: "Groceries", rows: ["ci_" <> _]}},
             {:checklist, %{list_id: id, title: "Groceries", rows: []}}
           ] = ReplyBlocks.take(context.reply_blocks, context.conversation_key)
  end

  test "a read and an edit each emit one event, with counts and no owner words", %{repo: repo} do
    TelemetryCapture.attach(
      [[:fermix, :checklist, :read], [:fermix, :checklist, :edit]],
      :emitter
    )

    changes = [
      %{
        "list" => "Secret plans",
        "ops" => [%{"op" => "create"}, %{"op" => "add", "text" => "Hidden"}]
      }
    ]

    {:ok, _} = Registry.edit(%{"changes" => changes}, @owner, repo: repo)
    {:error, _} = Registry.read(%{"list" => "Nope"}, @owner, repo: repo)

    assert_receive {:telemetry, [:fermix, :checklist, :edit], %{lists: 1, ops: 2, duration_us: _},
                    %{outcome: :ok, made_via: "chat", component: "checklists"} = edit}

    assert_receive {:telemetry, [:fermix, :checklist, :read], %{lists: 0},
                    %{outcome: :refused, error_code: "no_list", scope: :list} = read}

    for metadata <- [edit, read] do
      refute inspect(metadata) =~ "Secret"
      refute inspect(metadata) =~ "Hidden"
    end
  end
end
