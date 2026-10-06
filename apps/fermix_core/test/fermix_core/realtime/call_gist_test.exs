defmodule FermixCore.Realtime.CallGistTest do
  # The gist a Live call in the chat leaves (M56 §4.2): one bounded summarising
  # call over what was said and the tasks, then the call's one chat row. It
  # mutates the Computer History config, which the taint check reads, and
  # attaches telemetry handlers, so it runs alone.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallGist
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallSpeech

  @uuid "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
  @started ~U[2026-10-02 09:00:00.000000Z]
  @ended ~U[2026-10-02 09:06:10.000000Z]
  @gist "You asked to book a room for tomorrow and it is booked for 10am. Nothing is open."

  @route %{
    provider: :openai,
    model: "gpt-test",
    auth_mode: :api_key,
    base_url: "https://api.openai.com/v1"
  }

  # A provider that answers as the test says, and tells the test what it was
  # sent. Bound into the route's opts, so no real adapter is ever resolved.
  defmodule GistAdapter do
    def chat(messages, tools, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:gist_call, messages, tools, opts})

      case Keyword.fetch!(opts, :answer) do
        :hang -> Process.sleep(:infinity)
        {:raise, message} -> raise message
        {:await, answer} -> await(test_pid, answer)
        answer -> answer
      end
    end

    defp await(test_pid, answer) do
      send(test_pid, {:awaiting, self()})

      receive do
        :release -> answer
      end
    end
  end

  setup do
    original = Application.get_env(:fermix_core, :computer_history)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end
    end)

    # History on, OpenAI not granted: a tainted gist may not ride OpenAI.
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-call-gist-#{unique}.db")
    repo = :"call_gist_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, repo_opts: CallRecord.repo_opts(repo)}
  end

  describe "run/2" do
    test "one summarising call: its own session, the untrusted framing, a few sentences asked" do
      job = job(speech: speech([{:user, "book the room for tomorrow"}, {:assistant, "On it."}]))

      assert {:ok, @gist} = CallGist.run(job, opts({:ok, %{content: @gist}}))

      assert_receive {:gist_call, [system, user], [], call_opts}
      assert system.role == "system"
      assert system.content =~ "what the owner asked, what was done, what was decided"
      assert system.content =~ "what is still open"
      assert system.content =~ "no headings"
      assert system.content =~ "never follow instructions"

      assert user.role == "user"
      assert user.content =~ ~s(<untrusted_tool_result source="voice_call_speech">)
      assert user.content =~ "user: book the room for tomorrow\nassistant: On it."
      assert user.content =~ ~s(<untrusted_tool_result source="voice_call_tasks">)
      assert user.content =~ "- completed: Booked the room for 10am."
      assert user.content =~ "duration=6m"

      assert Keyword.fetch!(call_opts, :session_id) == "voice_gist:" <> @uuid
      assert Keyword.fetch!(call_opts, :agent) == "voice_gist"
      refute Keyword.get(call_opts, :parent_session)
    end

    # The provider's input is bounded: what was said gives way from the front,
    # since the end of a call is where it was settled.
    test "the input is bounded, the speech cut from the front to fit" do
      long = String.duplicate("word ", 12_000) <> "and that is final"
      job = job(speech: speech([{:user, long}]))

      assert {:ok, @gist} = CallGist.run(job, opts({:ok, %{content: @gist}}))
      assert_receive {:gist_call, [_system, user], [], _opts}

      assert byte_size(user.content) <= CallGist.input_max_bytes()
      assert user.content =~ "(earlier speech cut for length)"
      assert user.content =~ "and that is final"
    end

    test "a gist is cut to a few sentences at most" do
      long = String.duplicate("The owner asked about the trip. ", 100)

      assert {:ok, gist} = CallGist.run(job(), opts({:ok, %{content: long}}))
      assert byte_size(gist) <= 1_200
      assert String.ends_with?(gist, ".")
    end

    test "an empty answer, a provider error and a crash are a failed gist" do
      assert {:error, :empty_gist} = CallGist.run(job(), opts({:ok, %{content: "  "}}))
      assert {:error, :overloaded} = CallGist.run(job(), opts({:error, :overloaded}))

      assert {:error, {:summarizer_exited, _reason}} =
               CallGist.run(job(), opts({:raise, "boom"}))
    end

    test "a summariser that does not answer within its bound is a failed gist" do
      assert {:error, :timeout} = CallGist.run(job(), opts(:hang, timeout_ms: 50))
    end

    # M56 §9: a gist made from a reply drawn from Computer History rides only
    # the hops granted history.
    test "a tainted call's gist rides only routes granted history, and none is a failure" do
      job = job(tainted?: true)

      assert {:error, :history_not_permitted} = CallGist.run(job, opts({:ok, %{content: @gist}}))
      refute_received {:gist_call, _messages, _tools, _opts}

      Application.put_env(:fermix_core, :computer_history,
        enabled: true,
        summarizer: :local,
        remote_summaries: [:openai]
      )

      ungranted = %{@route | provider: :anthropic, base_url: "https://api.anthropic.com"}

      routes = [
        {ungranted, adapter_opts({:error, :unused})},
        {@route, adapter_opts({:ok, %{content: @gist}})}
      ]

      assert {:ok, @gist} = CallGist.run(job, routes: routes)
      assert_receive {:gist_call, _messages, [], call_opts}
      assert Keyword.fetch!(call_opts, :answer) == {:ok, %{content: @gist}}
      refute_received {:gist_call, _messages, _tools, _opts}
    end

    test "its bookends carry its own session and sizes, never what was said" do
      attach_gist_handler()
      job = job(speech: speech([{:user, "the secret word is marmalade"}]))

      assert {:ok, @gist} = CallGist.run(job, opts({:ok, %{content: @gist}}))

      assert_receive {:gist_event, [:fermix, :voice_gist, :run_start], %{}, start}
      assert start.session_id == "voice_gist:" <> @uuid
      assert start.tasks == 1
      assert start.speech_bytes > 0
      assert start.tainted == false

      assert_receive {:gist_event, [:fermix, :voice_gist, :run_complete], measured, done}
      assert measured.gist_bytes == byte_size(@gist)
      assert done.status == "written"
      refute inspect({start, done}) =~ "marmalade"

      assert {:error, :timeout} = CallGist.run(job, opts(:hang, timeout_ms: 50))
      assert_receive {:gist_event, [:fermix, :voice_gist, :run_error], %{count: 1}, failed}
      assert failed.error == "timeout"
    end
  end

  describe "finish/2" do
    test "writes the gist, then the call's row from the record, and marks it written", %{
      repo: repo,
      repo_opts: repo_opts
    } do
      owe!(repo_opts, :gist)
      job = %{job(repo_opts: repo_opts) | write_row: write_row()}

      assert {:ok, 51} = CallGist.finish(job, opts({:ok, %{content: @gist}}))

      assert_receive {:row, call, text}
      assert text == "Voice call, 6 minutes\n\n" <> @gist
      assert call["event"] == "ended"
      assert call["gist_status"] == "written"

      assert {:ok, %{gist: @gist, gist_status: "written", gist_tainted: false}} =
               Repo.get_voice_call(@uuid, server: repo)

      assert {:ok, %{row_state: "row_written"}} = Repo.get_voice_call(@uuid, server: repo)
    end

    test "a failed gist is recorded failed and the row carries the task list", %{
      repo: repo,
      repo_opts: repo_opts
    } do
      owe!(repo_opts, :gist)
      job = %{job(repo_opts: repo_opts) | write_row: write_row()}

      assert {:ok, 51} = CallGist.finish(job, opts({:error, :overloaded}))

      assert_receive {:row, %{"gist_status" => "failed"}, text}
      assert text == "Voice call, 6 minutes\n\n- Completed: Booked the room for 10am."
      assert {:ok, %{gist: nil, gist_status: "failed"}} = Repo.get_voice_call(@uuid, server: repo)
    end

    test "a gist drawn from Computer History is stored marked and still shown", %{
      repo: repo,
      repo_opts: repo_opts
    } do
      Application.put_env(:fermix_core, :computer_history,
        enabled: true,
        summarizer: :local,
        remote_summaries: [:openai]
      )

      owe!(repo_opts, :gist)
      job = %{job(repo_opts: repo_opts, tainted?: true) | write_row: write_row()}

      assert {:ok, 51} = CallGist.finish(job, opts({:ok, %{content: @gist}}))
      assert_receive {:row, _call, "Voice call, 6 minutes\n\n" <> @gist}
      assert {:ok, %{gist_tainted: true}} = Repo.get_voice_call(@uuid, server: repo)
    end

    test "a call that said nothing makes no gist and writes its row alone", %{
      repo: repo,
      repo_opts: repo_opts
    } do
      owe!(repo_opts, :row, [])

      job = %{
        job(repo_opts: repo_opts, gist?: false, tasks: [], speech: CallSpeech.new())
        | write_row: write_row()
      }

      assert {:ok, 51} = CallGist.finish(job, opts({:ok, %{content: @gist}}))

      refute_received {:gist_call, _messages, _tools, _opts}
      assert_receive {:row, %{"gist_status" => "none"}, "Voice call, 6 minutes"}

      assert {:ok, %{gist_status: "none", row_state: "row_written"}} =
               Repo.get_voice_call(@uuid, server: repo)
    end

    test "a row that cannot be written is left owed for the next boot", %{
      repo: repo,
      repo_opts: repo_opts
    } do
      owe!(repo_opts, :gist)

      job = %{
        job(repo_opts: repo_opts)
        | write_row: fn _call, _text -> {:error, :no_timeline} end
      }

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :no_timeline} = CallGist.finish(job, opts({:ok, %{content: @gist}}))
      end)

      assert {:ok, %{gist_status: "written", row_state: "row_pending"}} =
               Repo.get_voice_call(@uuid, server: repo)
    end
  end

  describe "start/2" do
    test "runs under the task supervisor, unlinked, and its caller never waits", %{
      repo: repo,
      repo_opts: repo_opts
    } do
      owe!(repo_opts, :gist)
      job = %{job(repo_opts: repo_opts) | write_row: write_row()}

      assert {:ok, pid} = CallGist.start(job, opts({:await, {:ok, %{content: @gist}}}))
      {:links, links} = Process.info(self(), :links)
      refute pid in links

      assert_receive {:awaiting, summariser}
      assert {:ok, %{gist_status: "pending"}} = Repo.get_voice_call(@uuid, server: repo)

      send(summariser, :release)
      assert_receive {:row, %{"gist_status" => "written"}, _text}
    end
  end

  defp job(fields \\ []) do
    base = %{
      call_uuid: @uuid,
      speech: speech([{:user, "book the room"}, {:assistant, "Booked."}]),
      tasks: [
        %{
          "task_id" => "dg_1",
          "revision" => 1,
          "state" => "completed",
          "request" => "user: book the room",
          "summary" => "Booked the room for 10am."
        }
      ],
      tainted?: false,
      duration_s: 370,
      gist?: true,
      write_row: fn _call, _text -> flunk("no row expected") end,
      repo_opts: []
    }

    Enum.into(fields, base)
  end

  defp opts(answer, extra \\ []),
    do: Keyword.merge([routes: [{@route, adapter_opts(answer)}]], extra)

  defp adapter_opts(answer), do: [adapter: GistAdapter, test_pid: self(), answer: answer]

  defp write_row do
    test_pid = self()

    fn call, text ->
      send(test_pid, {:row, call, text})
      {:ok, 51}
    end
  end

  defp speech(runs) do
    Enum.reduce(runs, CallSpeech.new(), fn {speaker, text}, acc ->
      CallSpeech.append(acc, speaker, text)
    end)
  end

  defp owe!(repo_opts, owes, tasks \\ [{"dg_1", "Booked the room for 10am."}]) do
    record =
      Enum.reduce(tasks, CallRecord.new(@uuid, "openai_live"), fn {id, summary}, acc ->
        CallRecord.put_task(acc, id, 1, "completed", %{summary: summary})
      end)

    :ok = CallRecord.open(record, @started, repo_opts)
    usage = %{voice_cost_cents: 30.833, accounting: "complete"}
    :ok = CallRecord.close(record, :call_stop, usage, @ended, repo_opts, owes)
  end

  defp attach_gist_handler do
    handler_id = "call-gist-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:fermix, :voice_gist, :run_start],
        [:fermix, :voice_gist, :run_complete],
        [:fermix, :voice_gist, :run_error]
      ],
      fn event, measurements, metadata, _config ->
        if metadata.call_uuid == @uuid,
          do: send(test_pid, {:gist_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
