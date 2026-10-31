defmodule FermixCore.Home.AlwaysOn do
  @moduledoc """
  Whether this engine is an Always On server (M75 L20), where Fermix keeps
  less on a disk its hosting provider can technically read: a trace keeps the
  bodies of its records about a day (through the previous UTC day) there
  (`FermixCore.Trace`).

  A server is the primary of a home that came to its host by a move or a
  restore, run by the Linux package on a machine with no Fermix app. Each fact
  is one the engine already records at boot, and each excludes a machine that
  is not a server:

    * the role is `primary` (`FermixCore.Home.Role`): a desktop and a
      candidate waiting for its move serve no conversation;
    * the install is the Linux package on Linux (`FermixCore.HostFacts`, from
      `FermixCore.BootProfile`): what an Always On server's first boot
      installs, and never the Mac app, a standalone binary or a source run;
    * no Fermix Linux app on the machine (`HostFacts`' `linux_app`): a Linux
      desktop runs the same package beside its app;
    * the primary epoch is above 1 (`FermixCore.Home.Epoch`): the home moved
      here or was restored here, the only two ways a home reaches an Always On
      server, so a Linux machine that has run its own home from the start
      keeps everything as before.

  `server?/1` decides on the facts alone; `facts/3` gathers them for a home
  from its boot's role record and host facts, so a test hands in the ones it
  means.
  """

  alias FermixCore.BootProfile
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Role
  alias FermixCore.HostFacts

  @type facts :: %{
          role: Role.role(),
          install: BootProfile.profile(),
          os: atom(),
          linux_app: boolean() | :not_asked,
          epoch: pos_integer() | nil
        }

  @doc "Whether `facts` describe an Always On server."
  @spec server?(facts()) :: boolean()
  def server?(%{
        role: :primary,
        install: :linux_package_cli,
        os: :linux,
        linux_app: false,
        epoch: epoch
      }),
      do: moved_or_restored?(epoch)

  def server?(%{role: role, install: install, os: os, linux_app: linux_app, epoch: epoch})
      when role in [:primary, :device, :candidate] and is_atom(install) and is_atom(os) and
             (is_boolean(linux_app) or linux_app == :not_asked) and
             (is_nil(epoch) or (is_integer(epoch) and epoch >= 1)),
      do: false

  defp moved_or_restored?(epoch) when is_integer(epoch) and epoch >= 1, do: epoch > 1
  defp moved_or_restored?(nil), do: false

  @doc """
  The facts for `home` under the boot's role `record` and `host` facts. Only
  a primary's epoch is read: a desktop and a candidate are no server whatever
  their home holds. An epoch file that is not one is raised by name.
  """
  @spec facts(Path.t(), Role.record(), HostFacts.t()) :: facts()
  def facts(home, %{role: role}, %{install: install, os: os, linux_app: linux_app})
      when is_binary(home) and home != "" do
    %{role: role, install: install, os: os, linux_app: linux_app, epoch: epoch(home, role)}
  end

  defp epoch(home, :primary) do
    case Epoch.read(home) do
      {:ok, epoch} -> epoch
      :absent -> nil
      {:error, reason} -> raise Epoch.error_sentence(reason)
    end
  end

  defp epoch(_home, role) when role in [:device, :candidate], do: nil
end
