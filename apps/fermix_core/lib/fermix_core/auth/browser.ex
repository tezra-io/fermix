defmodule FermixCore.Auth.Browser do
  @moduledoc """
  Cross-platform browser opener used by OAuth and setup flows.

  Returns `:ok` only when the OS command exits 0. The OS type, executable
  finder, and command runner are all injectable so tests can exercise the
  macOS / Linux / Windows branches without shelling out.
  """

  @type result ::
          :ok
          | {:error, :no_opener}
          | {:error, {:opener_failed, integer(), String.t()}}

  @type opts :: [
          os: {:unix, atom()} | {:win32, atom()},
          finder: (binary() -> binary() | nil),
          runner: (binary(), [binary()] -> {binary(), integer()})
        ]

  @spec open(String.t(), opts()) :: result()
  def open(url, opts \\ []) when is_binary(url) and is_list(opts) do
    os = Keyword.get(opts, :os, :os.type())
    finder = Keyword.get(opts, :finder, &System.find_executable/1)
    runner = Keyword.get(opts, :runner, &default_runner/2)

    {executable, args} = command_for(os, url)

    case finder.(executable) do
      nil -> {:error, :no_opener}
      path -> invoke(runner, path, args)
    end
  end

  defp invoke(runner, path, args) do
    case runner.(path, args) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:opener_failed, code, to_string(output)}}
    end
  end

  defp default_runner(path, args), do: System.cmd(path, args, stderr_to_stdout: true)

  defp command_for({:unix, :darwin}, url), do: {"open", [url]}
  defp command_for({:unix, _}, url), do: {"xdg-open", [url]}
  defp command_for({:win32, _}, url), do: {"cmd", ["/c", "start", "", url]}
end
