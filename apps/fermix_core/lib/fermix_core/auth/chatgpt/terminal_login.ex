defmodule FermixCore.Auth.ChatGPT.TerminalLogin do
  @moduledoc """
  Sign in with ChatGPT from a terminal: `fermix auth login` and the terminal
  setup wizard share it.

  The sign-in (`ChatGPT.login/1`) runs in a process of its own. While it waits
  for the browser, this module reads lines from the terminal and hands each one
  to it (`ChatGPT.paste_callback/2`), so a host with no browser, a server
  reached over SSH, can finish: open the address on another computer, then
  paste back the address that browser ended on. The sign-in checks a pasted
  address by the rules it applies to the browser's own callback, and keeps
  waiting after one that is not from this attempt.

  A browser that cannot be opened prints the address, and the wait goes on.

  The reader is stopped when the sign-in ends. A read it had already started is
  abandoned, and the terminal still hands that read the next line typed, so a
  line typed between the end of the sign-in and the next question is lost.
  """

  alias FermixCore.Auth.Browser
  alias FermixCore.Auth.ChatGPT

  require Logger

  @paste_prompt "Or paste the address your browser ended on:"
  # A person pastes a few addresses at most. Past this the reader stops, and the
  # browser's own callback can still finish the sign-in.
  @max_lines 20
  @login_opts [:fermix_path, :port, :timeout_ms, :req_options]

  @type opts :: [
          fermix_path: Path.t(),
          port: :inet.port_number(),
          timeout_ms: pos_integer(),
          req_options: keyword(),
          no_browser: boolean(),
          puts: (String.t() -> any()),
          read_line: (-> String.t() | :eof | {:error, term()}),
          browser: (String.t() -> :ok | {:error, term()}),
          login: (keyword() -> {:ok, map()} | {:error, term()})
        ]

  @doc """
  Runs one sign-in and answers what `ChatGPT.login/1` answers.

  `:fermix_path`, `:port`, `:timeout_ms` and `:req_options` go to the sign-in.
  `:no_browser` prints the address instead of opening it. `:puts` and
  `:read_line` are the terminal (`IO.puts/1` and a line from standard input);
  `:browser` and `:login` replace `Auth.Browser.open/1` and `ChatGPT.login/1`.
  """
  @spec run(opts()) ::
          {:ok, %{account: String.t() | nil, plan_usage: :on | :off}} | {:error, term()}
  def run(opts) when is_list(opts) do
    # Checked here, in the caller: the sign-in runs linked in a task, where the
    # same refusal (`ChatGPT.login/1`) would take the terminal down with it.
    :ok = validate_port!(Keyword.get(opts, :port))
    puts = Keyword.get(opts, :puts, &IO.puts/1)
    login = Keyword.get(opts, :login, &ChatGPT.login/1)
    read_line = Keyword.get(opts, :read_line, &read_line/0)

    login_opts =
      opts
      |> Keyword.take(@login_opts)
      |> Keyword.merge(opener: opener(opts, puts), puts: puts)

    sign_in = Task.async(fn -> login.(login_opts) end)
    reader = spawn_link(fn -> read_lines(sign_in.pid, read_line, @max_lines) end)

    # The sign-in bounds itself: its callback deadline, then requests that each
    # carry their own bounds (`RefreshClient.request_bounds/0`).
    result = Task.await(sign_in, :infinity)
    stop_reader(reader)
    result
  end

  defp validate_port!(nil), do: :ok
  defp validate_port!(port) when is_integer(port) and port in 0..65_535, do: :ok

  defp validate_port!(other),
    do: raise(ArgumentError, ":port must be a port number, got: #{inspect(other)}")

  defp opener(opts, puts) do
    if Keyword.get(opts, :no_browser, false) do
      fn url -> show_address(puts, url) end
    else
      browser = Keyword.get(opts, :browser, &Browser.open/1)
      fn url -> open_browser(browser, url, puts) end
    end
  end

  # The address is never logged: an OS opener's failure is named by its exit
  # status alone, since its output can echo the address it was given.
  defp open_browser(browser, url, puts) do
    case browser.(url) do
      :ok ->
        puts.("Your browser opened to sign in to ChatGPT.")
        puts.(@paste_prompt)
        :ok

      {:error, reason} ->
        Logger.warning(
          "ChatGPT sign-in: could not open a browser (#{opener_failure(reason)}); " <>
            "printing the address"
        )

        show_address(puts, url)
    end
  end

  defp show_address(puts, url) do
    puts.("Open this address in a browser to sign in to ChatGPT:\n  #{url}")
    puts.(@paste_prompt)
    :ok
  end

  defp opener_failure({:opener_failed, status, _output}), do: "exit #{status}"
  defp opener_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp opener_failure(_reason), do: "failed"

  defp read_lines(_sign_in, _read_line, 0), do: :ok

  defp read_lines(sign_in, read_line, left) do
    case read_line.() do
      line when is_binary(line) ->
        paste(sign_in, String.trim(line))
        read_lines(sign_in, read_line, left - 1)

      :eof ->
        :ok

      {:error, reason} ->
        Logger.warning("ChatGPT sign-in: stopped reading the terminal: #{inspect(reason)}")
    end
  end

  defp paste(_sign_in, ""), do: :ok
  defp paste(sign_in, url), do: ChatGPT.paste_callback(sign_in, url)

  defp stop_reader(reader) do
    Process.unlink(reader)
    Process.exit(reader, :kill)
    :ok
  end

  defp read_line, do: IO.gets("")
end
