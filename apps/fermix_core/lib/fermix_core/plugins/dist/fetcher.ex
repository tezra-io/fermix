defmodule FermixCore.Plugins.Dist.Fetcher do
  @moduledoc """
  Behaviour for fetching a plugin artifact to disk.

  The seam exists so the installer (a later stage) can be driven by a stub that
  serves fixture tarballs from a tmp dir — install tests never touch the
  network. The production implementation is `Fetcher.Http`, a thin wrapper over
  `FermixCore.Net.StreamDownload`.
  """

  @doc "Stream the artifact at `url` to `dest`. Only HTTP 200 is success."
  @callback fetch(url :: String.t(), dest :: Path.t()) :: :ok | {:error, term()}
end
