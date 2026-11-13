defmodule FermixCore.Trips.NoteTest do
  # M89 §04, C1, C8, C33: what the model is told of the owner's trips on its
  # private turns. Only while a trip exists: the rules, ending with the
  # channel's line (drawn, or write the days out), and one line naming the
  # trips with their dates, titles JSON-quoted, which moves when a trip is
  # made, renamed, redated or removed and never when a stop is added; nothing
  # at all with no trip, on any other turn, or with no store.
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Trips.Note
  alias FermixCore.Trips.Registry

  @owner %{
    agent_name: "main",
    conversation_key: {"telegram", "40061", :root},
    source_trust: :operator,
    computer_use_origin: :interactive,
    chat_type: "private",
    outside_sources: MapSet.new()
  }

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-trip-note-#{unique}.db")
    repo = :"trip_note_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, context: Map.put(@owner, :memory_repo, repo)}
  end

  defp edit!(repo, trip, ops) do
    {:ok, _answer} =
      Registry.edit(%{"trip" => trip, "ops" => ops}, @owner,
        repo: repo,
        notifier: fn _changes -> :ok end
      )
  end

  test "with no trip, nothing: the schemas alone (C8)", %{context: context} do
    assert Note.lines(context, "telegram", false) == %{rules: nil, index: nil}

    assert Note.lines(%{context | memory_repo: nil}, "telegram", false) == %{
             rules: nil,
             index: nil
           }
  end

  test "with a trip, the rules and the line naming the trips with their dates", %{
    repo: repo,
    context: context
  } do
    edit!(repo, "Varonne", [%{"op" => "create", "days" => 3, "starts_on" => "2031-07-04"}])
    edit!(repo, ~s(Kyoto "Hills"), [%{"op" => "create"}])

    %{rules: rules, index: index} = Note.lines(context, "telegram", false)

    assert index == ~s|The owner's trips: "Varonne" (4 to 6 Jul 2031); "Kyoto \\"Hills\\"".|

    assert rules =~ "read it with trip_read, change it with trip_edit, only as the owner asks"
    assert rules =~ "never what happens there"
    assert rules =~ "ask before moving a fixed stop"
    assert rules =~ "Make a trip and add what you already know before you search"
    assert rules =~ "and a new trip after one, wait for the owner"
    assert rules =~ "after their yes, with the place's link from that search"

    assert String.ends_with?(
             rules,
             "\nNo trip is drawn here: write out the days that changed, " <>
               "a stop a line with its time, each placed stop linked; trip_read with as: " <>
               "\"share\" gives them in that form."
           )

    %{rules: drawn} = Note.lines(context, "companion", true)
    assert drawn =~ "\nA trip you read or change is drawn under your reply, live"
    %{rules: written} = Note.lines(context, "companion", false)
    assert written =~ "\nNo trip is drawn here"
  end

  test "the line moves when a trip is made, renamed or redated, never on an added stop", %{
    repo: repo,
    context: context
  } do
    edit!(repo, "Varonne", [%{"op" => "create", "days" => 2, "starts_on" => "2031-07-04"}])
    %{index: before} = Note.lines(context, "telegram", false)

    edit!(repo, "Varonne", [%{"op" => "add", "text" => "Fish market", "day" => 1}])
    assert Note.lines(context, "telegram", false).index == before

    edit!(repo, "Varonne", [%{"op" => "dates", "starts_on" => "2031-08-01"}])
    assert Note.lines(context, "telegram", false).index =~ "(1 to 2 Aug 2031)"

    edit!(repo, "Varonne", [%{"op" => "rename", "text" => "Varonne coast"}])
    assert Note.lines(context, "telegram", false).index =~ ~s("Varonne coast")
  end

  test "a group chat's turn, a guest's and a job's are told nothing", %{
    repo: repo,
    context: context
  } do
    edit!(repo, "Varonne", [%{"op" => "create"}])

    job = %{
      context
      | conversation_key: {:scheduled_job, "job_1", "run_1"},
        agent_name: "scheduled:job_1"
    }

    for other <- [
          %{context | chat_type: "group"},
          %{context | source_trust: :guest},
          Map.merge(job, %{effective_trust: :operator, effective_allowed_tools: ["trip_read"]})
        ] do
      assert Note.lines(other, "telegram", false) == %{rules: nil, index: nil}, inspect(other)
    end
  end

  test "the line stays small with thirty trips" do
    trips =
      for n <- 1..30,
          do: %{title: "Trip number #{n}", starts_on: ~D[2031-07-04], days: 7}

    line = Note.index_line(trips)
    assert line =~ ~s|"Trip number 30" (4 to 10 Jul 2031).|
    # About 12 tokens a trip with its dates; 4 bytes a token bounds it here.
    assert byte_size(line) <= 30 * 48 + 40
  end
end
