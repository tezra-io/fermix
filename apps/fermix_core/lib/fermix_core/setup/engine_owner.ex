defmodule FermixCore.Setup.EngineOwner do
  @moduledoc """
  The advisory marker that records which engine last booted on this home
  (M34 native setup §15.2).

  One engine per home and one owner per home, decided by a two-state table
  rather than a precedence chain. **When a daemon answers on `daemon.sock`**,
  its `hello` decides and this marker is not read at all. **When no daemon
  answers**, the marker decides, and it says app-managed only while the bundle
  it records still exists at its recorded path. Two configurations, one path
  each, no second attempt after a first one fails.

  The bundle-exists half is not decoration. Without it, deleting the app leaves
  a stale marker that refuses `fermix start` forever, and the standalone boot
  that would rewrite it can never happen because that boot is the refused verb.

  It is a state file in the home, never a config key: nothing reads it to decide
  behaviour inside the daemon, and no install path has to seed it.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Setup.ConfigStore

  require Logger

  @file_name "engine-owner.json"
  @app_identity "macos_app"

  @type marker :: %{
          distribution_identity: String.t(),
          product_version: String.t(),
          build_id: String.t() | nil,
          app_bundle_path: String.t() | nil,
          written_at: String.t()
        }

  @doc "The marker path inside the configured home."
  @spec path(keyword()) :: String.t()
  def path(opts \\ []) when is_list(opts) do
    Keyword.get(opts, :path) || Path.join(ConfigStore.fermix_home(), @file_name)
  end

  @doc """
  Rewrites the marker for the engine that is booting.

  Called on every daemon boot so the recorded bundle path follows an app that
  moved, and so a standalone boot takes ownership back from a deleted app. A
  write failure is logged and never fatal: the marker is advisory, and a home
  whose marker cannot be written is answered by the live socket instead.
  """
  @spec record(keyword()) :: :ok
  def record(opts \\ []) when is_list(opts) do
    marker = %{
      "distribution_identity" => BuildInfo.distribution_identity(),
      "product_version" => BuildInfo.product_version(),
      "build_id" => Map.get(BuildInfo.public_identity(), "build_id"),
      "app_bundle_path" => Keyword.get(opts, :app_bundle_path) || app_bundle_path(),
      "written_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    case write(path(opts), marker) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("engine owner marker not written: #{inspect(reason)}")
        :ok
    end
  end

  @doc "The recorded marker, or `nil` when there is none this VM can read."
  @spec read(keyword()) :: marker() | nil
  def read(opts \\ []) when is_list(opts) do
    with {:ok, body} <- File.read(path(opts)),
         {:ok, %{} = decoded} <- Jason.decode(body) do
      normalize(decoded)
    else
      _absent_or_unreadable -> nil
    end
  end

  @doc """
  Whether the marker claims this home for an app whose bundle still exists.

  This is the "no daemon answered" arm of the ownership table, and only that
  arm. It answers false for every home with no marker, for a marker written by a
  standalone engine, and for a marker naming a bundle that has been removed.
  """
  @spec app_managed_marker?(keyword()) :: boolean()
  def app_managed_marker?(opts \\ []) when is_list(opts) do
    exists? = Keyword.get(opts, :bundle_exists?, &File.dir?/1)

    case read(opts) do
      %{distribution_identity: @app_identity, app_bundle_path: bundle} when is_binary(bundle) ->
        exists?.(bundle)

      _other ->
        false
    end
  end

  defp normalize(decoded) do
    %{
      distribution_identity: string_or_nil(decoded["distribution_identity"]),
      product_version: string_or_nil(decoded["product_version"]),
      build_id: string_or_nil(decoded["build_id"]),
      app_bundle_path: string_or_nil(decoded["app_bundle_path"]),
      written_at: string_or_nil(decoded["written_at"])
    }
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  # The running bundle is the directory the engine executable sits in, walked up
  # to the `.app`. Absent on a standalone engine, which is what makes a
  # standalone boot's marker unable to claim the home for an app.
  defp app_bundle_path do
    case :code.root_dir() |> to_string() |> String.split("/Contents/") do
      [bundle | _rest] -> if String.ends_with?(bundle, ".app"), do: bundle, else: nil
      _no_bundle -> nil
    end
  end

  defp write(path, marker) do
    with {:ok, body} <- Jason.encode(marker),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, body <> "\n")
    end
  end
end
