defmodule FermixCore.IMessage.Home do
  @moduledoc """
  The iMessage channel's state under `FERMIX_HOME/imessage/` (M54 §5.4):

      imessage/cursor    the acknowledged `{generation, rowid}` the Listener keeps
      imessage/helper/   the helper's own state, its send ledger among it
      imessage/inbox/    inbound attachments the helper copies per message
      imessage/outbox/   outbound files the engine hands the helper; the only
                         root `send.file` accepts

  Every directory is `0700`: the inbox and outbox carry message content, and
  the ledger carries what was sent to whom. The home is resolved through
  `FermixCore.Setup.ConfigStore.fermix_home/0` on every call, never cached.
  """

  alias FermixCore.Setup.ConfigStore

  @dir_mode 0o700

  @doc "The channel's directory, `FERMIX_HOME/imessage`."
  @spec dir() :: Path.t()
  def dir, do: Path.join(fermix_home(), "imessage")

  @doc """
  The `--home` the helper is given: `FERMIX_HOME` itself. The helper appends
  `imessage/` on its side, so the engine and the helper name every path from
  one root.
  """
  @spec fermix_home() :: Path.t()
  def fermix_home, do: ConfigStore.fermix_home()

  @doc "The acknowledged-cursor file the Listener writes by atomic rename."
  @spec cursor_path() :: Path.t()
  def cursor_path, do: Path.join(dir(), "cursor")

  @doc "The helper's own state directory."
  @spec helper_dir() :: Path.t()
  def helper_dir, do: Path.join(dir(), "helper")

  @doc "Where the helper copies inbound attachments."
  @spec inbox_dir() :: Path.t()
  def inbox_dir, do: Path.join(dir(), "inbox")

  @doc "Where the engine stages outbound files for `send.file`."
  @spec outbox_dir() :: Path.t()
  def outbox_dir, do: Path.join(dir(), "outbox")

  @doc """
  Creates the four directories at `0700`, repairing one an earlier run left at a
  wider mode. Answers with the directory it could not prepare.
  """
  @spec ensure() :: :ok | {:error, {:imessage_home, Path.t(), File.posix()}}
  def ensure do
    Enum.reduce_while([dir(), helper_dir(), inbox_dir(), outbox_dir()], :ok, fn path, :ok ->
      case ensure_dir(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:imessage_home, path, reason}}}
      end
    end)
  end

  defp ensure_dir(path) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, @dir_mode)
  end
end
