defmodule FermixChannels.Channels.IMessage.Bridge do
  @moduledoc """
  A Mac's Messages, carried for its server (M97 §6.4): this Mac's own
  helper (`IMessage.Port`, the code a Mac primary runs) and the watch that
  holds what it says for the server (`IMessage.Watch`), `:rest_for_one`, so
  a Port restart restarts the watch, which attaches again and tells the
  server the helper came back.

  Device-only (`FermixCore.Home.Role`): the server runs the listener and the
  adapter, which make turns; this Mac runs nothing that does. It starts on a
  Mac whose home is linked to its server and whose helper is installed, and
  answers `:ignore` anywhere else. The `imessage` switch is not read here:
  Admission reads it at each request (`Desktop.Invoke`), so switching
  Messages on or off at this Mac takes effect on the server's next request,
  and with it off nothing reaches the helper, which waits idle.

  Options, each a test's: `:home`, `:executable`, `:macos?`, `:name`.
  """

  use Supervisor

  require Logger

  alias FermixChannels.Channels.IMessage.Port, as: HelperPort
  alias FermixChannels.Channels.IMessage.Watch
  alias FermixCore.Home.DesktopLink
  alias FermixCore.IMessage
  alias FermixCore.IMessage.HelperInstaller
  alias FermixCore.IMessage.Home, as: IMessageHome
  alias FermixCore.Setup.ConfigStore

  @port __MODULE__.Port

  @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
  def start_link(opts \\ []) when is_list(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)

    with true <- Keyword.get_lazy(opts, :macos?, &IMessage.macos?/0),
         true <- File.regular?(DesktopLink.path(home)),
         {:ok, executable} <- executable(opts),
         :ok <- ensure_home(opts) do
      init_arg = [home: home, executable: executable]
      Supervisor.start_link(__MODULE__, init_arg, name: Keyword.get(opts, :name, __MODULE__))
    else
      false -> :ignore
      {:error, :not_installed} -> :ignore
      {:error, reason} -> refused(reason)
    end
  end

  @impl true
  def init(opts) do
    children = [
      {HelperPort, name: @port, executable: opts[:executable], home: opts[:home]},
      {Watch, name: Watch, helper: HelperPort, server: @port, home: opts[:home]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp executable(opts) do
    case Keyword.fetch(opts, :executable) do
      {:ok, path} -> {:ok, path}
      :error -> HelperInstaller.binary_path()
    end
  end

  defp ensure_home(opts),
    do: if(Keyword.has_key?(opts, :home), do: :ok, else: IMessageHome.ensure())

  defp refused(reason) do
    Logger.error("this Mac cannot carry Messages for its server: #{inspect(reason)}")
    :ignore
  end
end
