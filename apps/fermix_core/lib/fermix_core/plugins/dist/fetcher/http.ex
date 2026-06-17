defmodule FermixCore.Plugins.Dist.Fetcher.Http do
  @moduledoc """
  Production `Fetcher`: streams a plugin artifact straight to disk via
  `FermixCore.Net.StreamDownload` (the same download primitive the binary
  upgrade uses). No buffering, no retry beyond the shared client's.
  """

  @behaviour FermixCore.Plugins.Dist.Fetcher

  alias FermixCore.Net.StreamDownload

  @impl true
  def fetch(url, dest) when is_binary(url) and is_binary(dest) do
    StreamDownload.download(url, dest)
  end
end
