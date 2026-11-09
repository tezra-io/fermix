defmodule FermixCore.Home.Archive.InstanceRole do
  @moduledoc """
  An Always On server's own S3 bucket (E1): `[fermix_core.snapshots]`
  `s3_bucket` and `s3_region` with `s3_credentials = "instance_role"`, which
  that server's infrastructure named and its instance role signs for. It
  belongs to that one server, so wherever else the home becomes the primary
  the three are left out: a move back and a move to a server whose
  infrastructure named no bucket (`Candidate.Activation`, which writes them
  again for a server whose infrastructure did), and a restore on a Mac
  (`Archive.RestoredConfig`). A bucket set by hand with access keys is not
  this, and is left as it is. Every change goes through `Archive.ConfigText`,
  so every other byte of the file stays.
  """

  alias FermixCore.Home.Archive.ConfigText

  @section "fermix_core.snapshots"
  @keys ~w(s3_bucket s3_region s3_credentials)

  @doc "`text` without an instance-role bucket; any other text as it is."
  @spec drop(String.t()) :: String.t()
  def drop(text) when is_binary(text) do
    case ConfigText.value(text, @section, "s3_credentials") do
      {:ok, ~s("instance_role")} ->
        Enum.reduce(@keys, text, fn key, acc ->
          acc |> ConfigText.drop(@section, key) |> elem(0)
        end)

      _signed_otherwise ->
        text
    end
  end
end
