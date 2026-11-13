defmodule FermixCore.ComputerHistory.PromiseTest do
  # M97 §8.2: what switching computer history on agrees to, true where it is
  # said. A Mac that never moved has no server; a home with Always On in use
  # sends each finished sitting to its server.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Promise
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.DesktopLink
  alias FermixTestSupport.SafeRm

  setup do
    tmp = SafeRm.make_tmp_dir!("history-promise")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    %{home: tmp}
  end

  describe "sentence/2" do
    test "a Mac with no server names the provider and keeps the record here" do
      facts = %{server?: false, local?: false, provider: "Anthropic", machine: "Mac"}

      assert Promise.sentence(:footer, facts) ==
               "Fermix records what you do in the apps you choose on this Mac. The raw " <>
                 "record stays on this Mac for 48 hours; each finished sitting is summarized " <>
                 "by Anthropic, and Fermix keeps the summary."

      refute Promise.sentence(:footer, facts) =~ "server"
      refute Promise.sentence(:footer, facts) =~ "all your computers"
    end

    test "a Mac with no server that chose local summarizes on this Mac" do
      facts = %{server?: false, local?: true, provider: nil, machine: "Mac"}

      assert Promise.sentence(:footer, facts) =~
               "each finished sitting is summarized on this Mac, and Fermix keeps the summary."
    end

    test "with a server, each sitting goes to it, and every computer's summaries are recalled" do
      facts = %{server?: true, local?: false, provider: "Anthropic", machine: "Mac"}

      assert Promise.sentence(:footer, facts) ==
               "Fermix records what you do in the apps you choose on this Mac. The raw " <>
                 "record stays on this Mac for 48 hours; each finished sitting is sent to your " <>
                 "Fermix server, which has its summarizer summarize it and keeps the summary. " <>
                 "Summaries from all your computers can be recalled in chat."
    end

    test "with a server and a local summarizer, only the summary leaves this Mac" do
      facts = %{server?: true, local?: true, provider: nil, machine: "Mac"}

      assert Promise.sentence(:footer, facts) =~
               "each finished sitting is summarized on this Mac, and only the summary is sent " <>
                 "to your Fermix server, which keeps it."
    end

    # The clause a move's review adds: where the history goes once its line
    # is ticked, after the move, in a sentence the Always On pane keeps short
    # (its R1); the 48 hours stay the switch's footer's.
    test "the review's clause says where the history goes once ticked" do
      facts = %{server?: true, local?: false, provider: nil, machine: "Mac"}

      assert Promise.sentence(:clause, facts) ==
               " Ticked, each sitting of your computer history goes to your server, which " <>
                 "keeps its summary."

      assert Promise.sentence(:clause, %{facts | local?: true}) ==
               " Ticked, only the summary of each sitting of your computer history goes to " <>
                 "your server."
    end
  end

  describe "on_server?/1" do
    test "a home with no link and no server mark has no server", %{home: home} do
      refute Promise.on_server?(
               home: home,
               record: %{role: :primary, primary: nil},
               always_on?: true
             )
    end

    test "a computer linked to its server has one", %{home: home} do
      link!(home)
      device = %{role: :device, primary: "garden-server"}

      assert Promise.on_server?(home: home, record: device, always_on?: true)
      refute Promise.on_server?(home: home, record: device, always_on?: false)
    end

    test "the server itself has one", %{home: home} do
      File.mkdir_p!(Path.dirname(Candidate.server_path(home)))
      File.write!(Candidate.server_path(home), "{}")

      assert Promise.on_server?(
               home: home,
               record: %{role: :primary, primary: nil},
               always_on?: true
             )
    end

    test "a process that booted no engine has none", %{home: home} do
      link!(home)
      refute Promise.on_server?(home: home, record: nil, always_on?: true)
    end
  end

  describe "facts/2" do
    test "names the provider the status line names, and on this Mac for local", %{home: home} do
      base = [home: home, record: %{role: :primary, primary: nil}, always_on?: true, os: :macos]

      assert %{server?: false, local?: false, provider: "Anthropic", machine: "Mac"} =
               Promise.facts([summarizer: :anthropic], base)

      assert %{local?: true, provider: nil} =
               Promise.facts([machine_summarizer: :local, summarizer: :anthropic], base)

      assert %{machine: "computer"} =
               Promise.facts([summarizer: :anthropic], Keyword.put(base, :os, :linux))
    end
  end

  test "every sentence it says is listed for the copy rules" do
    sentences = Promise.sentences()

    assert length(sentences) >= 8
    footers = Enum.reject(sentences, &String.starts_with?(&1, " Ticked"))
    assert Enum.all?(footers, &(&1 =~ "48 hours"))
    refute Enum.any?(sentences, &(&1 =~ ~r/\d+\.\d+/))
  end

  defp link!(home) do
    File.mkdir_p!(Path.dirname(DesktopLink.path(home)))
    File.write!(DesktopLink.path(home), "{}")
  end
end
