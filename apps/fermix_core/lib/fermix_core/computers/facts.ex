defmodule FermixCore.Computers.Facts do
  @moduledoc """
  The facts of this machine an offer's state rests on (M97 §3.2): its
  system and processor, whether the kernel holds commands to the sandbox
  (Landlock, on Linux), which helpers are installed (the computer use
  helper) or carried (`apple_maps`, the Apple Maps helper, a fact of the
  build: `PlaceSearch.Backend.carries_helper?/1`), the permissions known
  to be missing, the sandbox mode its commands run in, the folders its
  files and commands reach (`roots`, the sandbox's effective roots,
  `Sandbox.Mode.effective_roots/1`: what the files and shell capabilities
  hold a path to here, M97 §6.4), the folder a path's `~` stands for here
  (`home`, `Sandbox.PathPolicy.tilde_home/0`), whether it has a recorder
  (`recorder`, `ComputerHistory.recorder?/1` for its system: its paired
  helper records there) and whether that recorder is switched on
  (`recording`, the Computer history section's own setting, which the
  history offer follows, M97 D27). The sandbox is the one the capabilities
  run under (`Sandbox.Config.current/0`).

  `read/1` reads each through the module that owns it, and takes each as an
  option instead (`os:`, `arch:`, `landlock:`, `helpers:`, `permissions:`,
  `sandbox_mode:`, `roots:`, `home:`, `recorder:`, `recording:`), so a test names the
  machine it means and never reads the one it runs on.

  Permissions are what is known to be missing: only the computer use helper
  itself can say whether the screen may be seen and controlled, and asking
  it starts it, so this reader asks nothing and a caller that knows passes
  them (`permissions: %{screen: false}`); unknown refuses nothing.

  `screen` is what this computer's screen helper offers, as its latest
  reading says (`ComputerUse.Reach.offered_helper/0`: its actions, with this
  computer's bound-window flag applied, and its input methods), which the
  `computer_use` offer carries to the server (M97 §6.4); `screen:` names it.
  """

  alias FermixCore.BootProfile
  alias FermixCore.BuildInfo
  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerUse.Reach
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.Landlock
  alias FermixCore.Sandbox.Mode
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.PlaceSearch.Backend, as: PlaceBackend

  @typedoc "The facts of one machine."
  @type t :: %{
          required(:os) => :macos | :linux | :other,
          required(:arch) => String.t(),
          required(:landlock) => :ok | :not_asked | {:error, String.t()},
          required(:helpers) => %{
            optional(:computer_use) => boolean(),
            optional(:apple_maps) => boolean()
          },
          required(:permissions) => %{optional(:screen) => boolean()},
          required(:sandbox_mode) => :strict | :standard | :open,
          required(:roots) => [String.t()],
          required(:home) => String.t(),
          required(:recorder) => boolean(),
          required(:recording) => boolean(),
          optional(:screen) => %{actions: [String.t()], input_methods: [String.t()]}
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
      sandbox_mode: Keyword.get_lazy(opts, :sandbox_mode, fn -> SandboxConfig.current().mode end),
      roots:
        Keyword.get_lazy(opts, :roots, fn -> Mode.effective_roots(SandboxConfig.current()) end),
      home: Keyword.get_lazy(opts, :home, &PathPolicy.tilde_home/0),
      recorder:
        Keyword.get_lazy(opts, :recorder, fn -> ComputerHistory.recorder?(system: os) end),
      recording: Keyword.get_lazy(opts, :recording, &ComputerHistory.enabled?/0),
      screen: Keyword.get_lazy(opts, :screen, &Reach.offered_helper/0)
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

  defp helpers,
    do: %{
      computer_use: SidecarInstaller.installed?(),
      apple_maps: PlaceBackend.carries_helper?(BootProfile.host())
    }
end
