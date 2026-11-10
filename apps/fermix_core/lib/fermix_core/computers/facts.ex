defmodule FermixCore.Computers.Facts do
  @moduledoc """
  The facts of this machine an offer's state rests on (M97 §3.2): its
  system and processor, whether the kernel holds commands to the sandbox
  (Landlock, on Linux), which helpers are installed, the permissions known
  to be missing, and the sandbox mode its commands run in.

  `read/1` reads each through the module that owns it, and takes each as an
  option instead (`os:`, `arch:`, `landlock:`, `helpers:`, `permissions:`,
  `sandbox_mode:`), so a test names the machine it means and never reads the
  one it runs on.

  Permissions are what is known to be missing: only the computer use helper
  itself can say whether the screen may be seen and controlled, and asking
  it starts it, so this reader asks nothing and a caller that knows passes
  them (`permissions: %{screen: false}`); unknown refuses nothing.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Landlock

  @typedoc "The facts of one machine."
  @type t :: %{
          os: :macos | :linux | :other,
          arch: String.t(),
          landlock: :ok | :not_asked | {:error, String.t()},
          helpers: %{optional(:computer_use) => boolean()},
          permissions: %{optional(:screen) => boolean()},
          sandbox_mode: :strict | :standard | :open
        }

  @doc "The facts of this machine, each from its option when one is given."
  @spec read(keyword()) :: t()
  def read(opts \\ []) when is_list(opts) do
    os = Keyword.get_lazy(opts, :os, &os/0)

    %{
      os: os,
      arch: Keyword.get_lazy(opts, :arch, fn -> BuildInfo.identity().architecture end),
      landlock: Keyword.get_lazy(opts, :landlock, fn -> landlock(os) end),
      helpers: Keyword.get_lazy(opts, :helpers, &helpers/0),
      permissions: Keyword.get(opts, :permissions, %{}),
      sandbox_mode: Keyword.get_lazy(opts, :sandbox_mode, &sandbox_mode/0)
    }
  end

  @doc ~s(What a person calls this kind of machine: "Mac", or "computer".)
  @spec machine(t()) :: String.t()
  def machine(%{os: :macos}), do: "Mac"
  def machine(%{os: _other}), do: "computer"

  defp os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      _other -> :other
    end
  end

  # Only Linux needs the kernel's word: a Mac holds commands with Seatbelt.
  defp landlock(:linux) do
    case Landlock.probe(Landlock.shim_path()) do
      {:ok, _abi} -> :ok
      {:error, reason} -> {:error, Landlock.describe(reason)}
    end
  end

  defp landlock(_os), do: :not_asked

  defp helpers, do: %{computer_use: SidecarInstaller.installed?()}

  defp sandbox_mode,
    do: SandboxConfig.normalize(Application.get_env(:fermix_core, :sandbox)).mode
end
