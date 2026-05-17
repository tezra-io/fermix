defmodule FermixCore.Sandbox.Hardline do
  @moduledoc """
  Pure classifier for catastrophic shell commands.

  NOTE: M5 intentionally catches common operator-accident patterns only. M10
  owns Unicode normalization, command alias expansion, and deeper shell parsing.
  """

  @protected_targets MapSet.new(~w(~ $HOME /etc /usr /bin /sbin /System /Library))

  @spec classify(String.t()) :: :allow | {:hardline, String.t()}
  def classify(command) when is_binary(command) do
    normalized = normalize(command)

    cond do
      recursive_delete_root?(normalized) -> {:hardline, "recursive delete of a protected root"}
      mkfs?(normalized) -> {:hardline, "filesystem formatting command"}
      dd_block_device_write?(normalized) -> {:hardline, "block-device write through dd"}
      fork_bomb?(normalized) -> {:hardline, "fork bomb pattern"}
      kill_all?(normalized) -> {:hardline, "kill-all process pattern"}
      shutdown?(normalized) -> {:hardline, "shutdown or reboot command"}
      sudo_stdin_password?(normalized) -> {:hardline, "sudo password read from stdin"}
      true -> :allow
    end
  end

  def classify(_command), do: {:hardline, "command must be a string"}

  defp recursive_delete_root?(command) do
    command
    |> String.split(~r/\s+/, trim: true)
    |> rm_args()
    |> case do
      {:ok, args} -> recursive_rm_args?(args)
      :error -> false
    end
  end

  defp rm_args(["rm" | args]), do: {:ok, args}
  defp rm_args(["\\rm" | args]), do: {:ok, args}
  defp rm_args(["/bin/rm" | args]), do: {:ok, args}
  defp rm_args(["/usr/bin/rm" | args]), do: {:ok, args}
  defp rm_args(["'rm'" | args]), do: {:ok, args}
  defp rm_args(["command", "rm" | args]), do: {:ok, args}
  defp rm_args(_tokens), do: :error

  defp recursive_rm_args?(args) do
    flags = Enum.filter(args, &String.starts_with?(&1, "-"))
    targets = args -- flags

    Enum.any?(flags, &String.contains?(&1, "r")) and Enum.any?(targets, &protected_target?/1)
  end

  defp protected_target?(target) do
    target = String.trim_trailing(target, "/")
    target == "" or MapSet.member?(@protected_targets, target)
  end

  defp mkfs?(command), do: Regex.match?(~r/(^|\s)mkfs(\.\w+)?\s+/, command)
  defp dd_block_device_write?(command), do: Regex.match?(~r/(^|\s)dd\s+.*\bof=\/dev\//, command)
  defp fork_bomb?(command), do: String.contains?(command, ":(){ :|:& };:")

  defp kill_all?(command),
    do: Regex.match?(~r/(^|\s)(kill\s+(-9\s+)?-1|pkill\s+.*-u\s+\$USER)/, command)

  defp shutdown?(command),
    do:
      Regex.match?(
        ~r/(^|\s)(shutdown|reboot|poweroff|systemctl\s+poweroff|init\s+0)(\s|$)/,
        command
      )

  defp sudo_stdin_password?(command), do: Regex.match?(~r/(^|\s)sudo\s+[^;\n|&]*-S\b/, command)

  defp normalize(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
