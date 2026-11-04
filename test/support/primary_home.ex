defmodule FermixTestSupport.PrimaryHome do
  @moduledoc """
  A temporary home as a primary boot leaves it (M75 D14): its primary epoch at
  1. The engine writes the first epoch once, at the home's first boot as the
  primary, before the phone subtree starts, and `Mobile.Identity` never writes
  one. A test that creates a phone identity on a fresh root starts here.
  """

  alias FermixCore.Home.Epoch

  @doc "Creates `root` if it is missing and writes its primary epoch, 1. Returns `root`."
  @spec booted!(Path.t()) :: Path.t()
  def booted!(root) when is_binary(root) and root != "" do
    File.mkdir_p!(root)
    :ok = Epoch.write(root, 1)
    root
  end
end
