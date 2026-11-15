defmodule FermixCore.Home.ComputerName do
  @moduledoc """
  The name a person knows this computer by, which Always On shows on the
  other side of a move (M75): the primary's in its enrollment code, a
  candidate's in the servers its primary holds, and a desktop's in the
  server's desktops.

  On a Mac it is the computer name its owner set in System Settings
  (General > Sharing), read with `scutil --get ComputerName`: the BSD hostname
  a Mac derives from it, or from its network, is not a name its owner chose.
  Every other computer is named by its hostname, so a server keeps its own.

  At most 64 bytes, cut between characters. A name that cannot be read is an
  error with its reason, never a stand-in.

  `opts`: `:os_type` (as `:os.type/0` answers), `:scutil` (a 0-arity reader of
  the computer name: `{:ok, output} | {:error, reason}`) and `:hostname`
  (0-arity, as `:inet.gethostname/0`). A test VM reads the hostname unless a
  case names `:os_type`, so no test reads a Mac's computer name.
  """

  alias FermixCore.CommandRunner

  @scutil "/usr/sbin/scutil"
  @timeout_ms 2_000
  @max_bytes 64
  @compiled_env Mix.env()

  @spec read(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def read(opts \\ []) when is_list(opts) do
    case Keyword.get_lazy(opts, :os_type, &os_type/0) do
      {:unix, :darwin} -> opts |> Keyword.get(:scutil, &run_scutil/0) |> computer_name()
      _other -> opts |> Keyword.get(:hostname, &:inet.gethostname/0) |> host_name()
    end
  end

  defp computer_name(reader) do
    with {:ok, output} <- reader.() do
      named(output, "this Mac has no computer name")
    end
  end

  defp host_name(reader) do
    case reader.() do
      {:ok, name} -> named(to_string(name), "this computer has no hostname")
      {:error, reason} -> {:error, "the hostname could not be read: #{inspect(reason)}"}
    end
  end

  defp named(text, none) do
    case String.trim(text) do
      "" -> {:error, none}
      name -> {:ok, bounded(name)}
    end
  end

  defp bounded(name) do
    name
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, kept ->
      if byte_size(kept) + byte_size(grapheme) > @max_bytes,
        do: {:halt, kept},
        else: {:cont, kept <> grapheme}
    end)
  end

  defp run_scutil do
    case CommandRunner.run(@scutil, ["--get", "ComputerName"],
           timeout_ms: @timeout_ms,
           supervised: false
         ) do
      {:ok, %{exit: 0, stdout: out}} -> {:ok, out}
      {:ok, %{exit: code, stdout: out}} -> {:error, "scutil exited #{code}: #{String.trim(out)}"}
      {:error, reason} -> {:error, "scutil could not run: #{inspect(reason)}"}
    end
  end

  # A test VM reads no Mac's computer name; a case names `:os_type` to see one.
  defp os_type, do: if(@compiled_env == :test, do: {:unix, :linux}, else: :os.type())
end
