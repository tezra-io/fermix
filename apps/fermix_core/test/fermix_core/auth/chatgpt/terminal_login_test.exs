defmodule FermixCore.Auth.ChatGPT.TerminalLoginTest do
  # The terminal's Sign in with ChatGPT, shared by `fermix auth login` and the
  # terminal setup wizard. Every seam is injected: no browser opens, no
  # standard input is read and nothing reaches OpenAI.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Auth.ChatGPT.TerminalLogin

  @authorize "https://auth.openai.com/api/accounts/authorize?state=S"
  @signed_in {:ok, %{account: "owner@example.com", plan_usage: :on}}

  describe "a pasted address" do
    test "each line typed while the sign-in waits reaches it, trimmed, blank lines skipped" do
      parent = self()
      first = "http://127.0.0.1:1455/auth/callback?code=OLD&state=X"
      second = "http://127.0.0.1:1455/auth/callback?code=C&state=S"

      login = fn opts ->
        :ok = Keyword.fetch!(opts, :opener).(@authorize)
        send(parent, {:pasted, receive_paste()})
        send(parent, {:pasted, receive_paste()})
        @signed_in
      end

      assert @signed_in =
               TerminalLogin.run(
                 login: login,
                 read_line: lines(["#{first}\n", "   \n", "  #{second}\n"]),
                 browser: fn _url -> :ok end,
                 puts: collect(parent)
               )

      assert_received {:pasted, ^first}
      assert_received {:pasted, ^second}
    end

    test "end of input stops reading, and the browser can still finish the sign-in" do
      parent = self()

      login = fn opts ->
        :ok = Keyword.fetch!(opts, :opener).(@authorize)
        @signed_in
      end

      read_line = fn ->
        send(parent, :read)
        :eof
      end

      assert @signed_in =
               TerminalLogin.run(
                 login: login,
                 read_line: read_line,
                 browser: fn _url -> :ok end,
                 puts: collect(parent)
               )

      assert_received :read
      refute_received :read
    end

    # A read the reader started is abandoned when the sign-in ends, so the
    # terminal is not left with a reader pasting into a sign-in that is gone.
    test "the reader is stopped when the sign-in ends" do
      parent = self()
      {:ok, reads} = Agent.start_link(fn -> 0 end)

      # The first read answers, so the sign-in knows the reader runs; the
      # second never does, as a terminal nobody types into.
      read_line = fn ->
        case Agent.get_and_update(reads, &{&1, &1 + 1}) do
          0 ->
            send(parent, {:reader, self()})
            "http://127.0.0.1:1455/auth/callback?code=C&state=S\n"

          _later ->
            receive do
              :never_sent -> "never"
            end
        end
      end

      login = fn _opts ->
        _url = receive_paste()
        {:error, :callback_timeout}
      end

      assert {:error, :callback_timeout} =
               TerminalLogin.run(login: login, read_line: read_line, puts: collect(parent))

      assert_received {:reader, reader}
      down = Process.monitor(reader)
      assert_receive {:DOWN, ^down, :process, ^reader, _reason}
    end
  end

  describe "the address and the prompt" do
    test "a browser that opens is followed by the paste prompt" do
      parent = self()

      login = fn opts ->
        :ok = Keyword.fetch!(opts, :opener).(@authorize)
        @signed_in
      end

      TerminalLogin.run(
        login: login,
        read_line: lines([]),
        browser: fn url ->
          send(parent, {:opened, url})
          :ok
        end,
        puts: collect(parent)
      )

      assert_received {:opened, @authorize}

      assert printed() == [
               "Your browser opened to sign in to ChatGPT.",
               "Or paste the address your browser ended on:"
             ]
    end

    # The address is printed for a person to open elsewhere and never logged:
    # an opener's failure is named by its exit status alone.
    test "a browser that cannot open prints the address, and the wait goes on" do
      parent = self()

      login = fn opts ->
        :ok = Keyword.fetch!(opts, :opener).(@authorize)
        @signed_in
      end

      {result, log} =
        with_log(fn ->
          TerminalLogin.run(
            login: login,
            read_line: lines([]),
            browser: fn _url -> {:error, {:opener_failed, 3, "xdg-open: #{@authorize}"}} end,
            puts: collect(parent)
          )
        end)

      assert result == @signed_in

      assert printed() == [
               "Open this address in a browser to sign in to ChatGPT:\n  #{@authorize}",
               "Or paste the address your browser ended on:"
             ]

      assert log =~ "could not open a browser (exit 3)"
      refute log =~ "auth.openai.com"
    end

    test "--no-browser prints the address and opens nothing" do
      parent = self()

      login = fn opts ->
        send(parent, {:login_keys, opts |> Keyword.keys() |> Enum.sort()})
        :ok = Keyword.fetch!(opts, :opener).(@authorize)
        @signed_in
      end

      TerminalLogin.run(
        login: login,
        no_browser: true,
        port: 1455,
        timeout_ms: 30_000,
        read_line: lines([]),
        browser: fn _url -> flunk("--no-browser must open nothing") end,
        puts: collect(parent)
      )

      assert_received {:login_keys, [:opener, :port, :puts, :timeout_ms]}
      assert [address, "Or paste the address your browser ended on:"] = printed()
      assert address =~ @authorize
    end
  end

  test "a port that is not one is refused before the sign-in starts" do
    login = fn _opts -> flunk("the sign-in must not start") end

    assert_raise ArgumentError, ~r/:port must be a port number/, fn ->
      TerminalLogin.run(login: login, port: 70_000, read_line: lines([]))
    end
  end

  defp receive_paste do
    receive do
      {:chatgpt_callback, url} -> url
    after
      2_000 -> flunk("no pasted address reached the sign-in")
    end
  end

  defp lines(lines) do
    {:ok, agent} = Agent.start_link(fn -> lines end)

    fn ->
      Agent.get_and_update(agent, fn
        [] -> {:eof, []}
        [line | rest] -> {line, rest}
      end)
    end
  end

  defp collect(parent), do: fn line -> send(parent, {:printed, line}) end

  defp printed(acc \\ []) do
    receive do
      {:printed, line} -> printed([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
