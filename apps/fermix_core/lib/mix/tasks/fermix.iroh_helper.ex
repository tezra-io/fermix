defmodule Mix.Tasks.Fermix.IrohHelper do
  @shortdoc "Installs this host's pinned fermix-iroh helper into the source checkout"

  @moduledoc """
  Installs the pinned `fermix-iroh` helper for this host into the source
  checkout, so a development daemon can offer "Reach from anywhere" (M62):

      mix fermix.iroh_helper

  Release builds carry the helper; a checkout has none until this runs. It puts
  the host's pinned helper at `apps/fermix_core/priv/iroh_helper/bin/fermix-iroh`
  (git ignores `bin/`) through `FermixCore.Release.IrohHelper.place/3`: a helper
  already there with the pinned digest is kept, anything else is fetched once
  from the pinned release and checked against the pin. Nothing else installs
  it. Restart the daemon afterwards; it looks for the helper when it starts.
  """

  use Mix.Task

  alias FermixCore.Release.IrohHelper

  @usage "usage: mix fermix.iroh_helper"

  @impl Mix.Task
  def run(args) do
    # Compiled code only: the task starts no application of this project.
    Mix.Task.run("compile")
    execute(args)
  end

  @doc false
  # `opts` stand in for the host and the tree in tests: `:os_type`,
  # `:system_architecture`, `:priv_dir`, and `place/3`'s `:pin_path` and `:fetch`.
  @spec execute([String.t()], keyword()) :: :ok
  def execute(args, opts \\ []) when is_list(args) and is_list(opts) do
    if args != [], do: Mix.raise(@usage)

    os_type = Keyword.get_lazy(opts, :os_type, &:os.type/0)

    architecture =
      Keyword.get_lazy(opts, :system_architecture, fn ->
        :erlang.system_info(:system_architecture)
      end)

    target = host_target!(os_type, architecture)
    priv_dir = Keyword.get(opts, :priv_dir, default_priv_dir())

    target
    |> IrohHelper.place(priv_dir, Keyword.take(opts, [:pin_path, :fetch]))
    |> say(target)
  end

  @doc false
  @spec default_priv_dir() :: Path.t()
  def default_priv_dir, do: IrohHelper.source_priv_dir()

  @doc false
  # The Burrito target alias the pin names for one host.
  @spec host_target({atom(), atom()}, charlist()) :: {:ok, String.t()} | :unsupported
  def host_target(os_type, architecture) when is_tuple(os_type) and is_list(architecture) do
    with {:ok, os} <- host_os(os_type),
         {:ok, cpu} <- host_cpu(to_string(architecture)) do
      {:ok, "#{os}_#{cpu}"}
    end
  end

  defp host_os({:unix, :darwin}), do: {:ok, "macos"}
  defp host_os({:unix, :linux}), do: {:ok, "linux"}
  defp host_os(_other), do: :unsupported

  defp host_cpu("aarch64" <> _rest), do: {:ok, "aarch64"}
  defp host_cpu("arm64" <> _rest), do: {:ok, "aarch64"}
  defp host_cpu("x86_64" <> _rest), do: {:ok, "x86_64"}
  defp host_cpu(_other), do: :unsupported

  defp host_target!(os_type, architecture) do
    case host_target(os_type, architecture) do
      {:ok, target} ->
        target

      :unsupported ->
        Mix.raise(
          "fermix-iroh is built for macOS and Linux on aarch64 and x86_64, and this host is " <>
            "#{inspect(os_type)} #{architecture}"
        )
    end
  end

  defp say(%{action: :placed, path: path, version: version}, target) do
    Mix.shell().info("Placed fermix-iroh #{version} for #{target} at #{path}.")
  end

  defp say(%{action: :kept, path: path, version: version}, target) do
    Mix.shell().info("fermix-iroh #{version} for #{target} is already at #{path}; kept it.")
  end
end
