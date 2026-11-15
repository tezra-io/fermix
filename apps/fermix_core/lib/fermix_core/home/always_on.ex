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
    * no Fermix Linux app on the machine (`HostFacts`' `linux_app`, its .deb
      or .rpm package or the earlier Flatpak): a Linux desktop runs the same
      engine, in the app's own package or beside its Flatpak;
    * the primary epoch is above 1 (`FermixCore.Home.Epoch`): the home moved
      here or was restored here, the only two ways a home reaches an Always On
      server, so a Linux machine that has run its own home from the start
      keeps everything as before.

  `server?/1` decides on the facts alone; `facts/3` gathers them for a home
  from its boot's role record and host facts, so a test hands in the ones it
  means; `here?/1` is the question every surface asks of this engine, in a
  booted engine and in a tree-less verb alike.
  """

  alias FermixCore.BootProfile
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Role
  alias FermixCore.HostFacts
  alias FermixCore.Setup.ConfigStore

  require Logger

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
  Whether this engine is an Always On server, the one rule every surface
  that differs on one asks (computer history's recorder, Google Meet):
  `server?/1` of this home's facts. A booted engine's are the ones its boot
  recorded (`Role.booted/0`, `HostFacts.current/0`); a process that booted
  none (a tree-less verb such as `fermix doctor`) reads the same facts for
  this home now: the role it is configured for (`Role.configured/1`) and
  this host's facts, through the reader boot uses (`HostFacts.read_here/0`).
  Then the home's epoch.

  A fact that cannot be read is logged and answers true, so a surface that
  holds back what a server cannot do holds it back (it fails closed).

  `opts` (a test's seams): `:home`, `:booted` (the boot's record, or nil for
  a process that booted none) and `:host_facts`.
  """
  @spec here?(keyword()) :: boolean()
  def here?(opts \\ []) when is_list(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)

    case read_facts(home, Keyword.get_lazy(opts, :booted, &Role.booted/0), opts) do
      {:ok, facts} ->
        server?(facts)

      {:error, sentence} ->
        Logger.error("always on: #{sentence}; this engine is taken for an Always On server")
        true
    end
  end

  defp read_facts(home, booted, opts) do
    with {:ok, record} <- record(booted, home) do
      gather(home, record, Keyword.get_lazy(opts, :host_facts, fn -> host_facts(booted) end))
    end
  end

  defp record(%{} = booted, _home), do: {:ok, booted}

  defp record(nil, home) do
    case Role.configured(home) do
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, Role.error_sentence(reason)}
    end
  end

  defp host_facts(%{}), do: HostFacts.current()
  defp host_facts(nil), do: HostFacts.read_here()

  @doc """
  The facts for `home` under the boot's role `record` and `host` facts. Only
  a primary's epoch is read: a desktop and a candidate are no server whatever
  their home holds. An epoch file that is not one is raised by name.
  """
  @spec facts(Path.t(), Role.record(), HostFacts.t()) :: facts()
  def facts(home, record, host) when is_binary(home) and home != "" do
    case gather(home, record, host) do
      {:ok, facts} -> facts
      {:error, sentence} -> raise sentence
    end
  end

  defp gather(home, %{role: role}, %{install: install, os: os, linux_app: linux_app}) do
    with {:ok, epoch} <- epoch(home, role) do
      {:ok, %{role: role, install: install, os: os, linux_app: linux_app, epoch: epoch}}
    end
  end

  defp epoch(home, :primary) do
    case Epoch.read(home) do
      {:ok, epoch} -> {:ok, epoch}
      :absent -> {:ok, nil}
      {:error, reason} -> {:error, Epoch.error_sentence(reason)}
    end
  end

  defp epoch(_home, role) when role in [:device, :candidate], do: {:ok, nil}
end
