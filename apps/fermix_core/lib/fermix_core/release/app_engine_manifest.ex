defmodule FermixCore.Release.AppEngineManifest do
  @moduledoc """
  Builds the immutable metadata embedded in a plain macOS app-engine tree.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Release.ExecutableInventory
  alias FermixCore.Release.Tree

  @filename "engine-manifest.json"
  @schema_version 1
  @oidc_issuer "https://token.actions.githubusercontent.com"
  @workflow_identity "https://github.com/tezra-io/fermix/.github/workflows/release.yml"

  @doc "Builds a manifest from one assembled release tree."
  @spec build(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(root, opts \\ []) when is_binary(root) and is_list(opts) do
    identity = Keyword.get(opts, :identity, BuildInfo.identity())
    protocols = Keyword.get(opts, :protocols, BuildInfo.protocols())
    classifier = Keyword.get(opts, :classifier, &ExecutableInventory.classify/1)

    with :ok <- BuildInfo.validate_app_engine(identity),
         {:ok, public_protocols} <- public_protocols(protocols),
         {:ok, nodes} <- Tree.scan(root, exclude: [@filename]),
         {:ok, tree_sha256} <- Tree.digest(nodes),
         {:ok, entries} <-
           ExecutableInventory.build(nodes, identity.architecture, classifier: classifier) do
      {:ok, manifest(identity, public_protocols, tree_sha256, entries)}
    end
  end

  @doc "Writes the manifest atomically into the assembled release root."
  @spec write(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(root, opts \\ []) when is_binary(root) and is_list(opts) do
    with {:ok, writer} <- write_file(opts),
         {:ok, manifest} <- build(root, opts),
         {:ok, encoded} <- Jason.encode(manifest, pretty: true),
         :ok <- write_atomic(root, encoded <> "\n", writer) do
      {:ok, manifest}
    end
  end

  @doc "Returns the fixed in-tree manifest filename."
  @spec filename() :: String.t()
  def filename, do: @filename

  defp manifest(identity, protocols, tree_sha256, entries) do
    %{
      "schema_version" => @schema_version,
      "identity" => public_identity(identity),
      "protocols" => protocols,
      "provenance" => %{
        "oidc_issuer" => @oidc_issuer,
        "certificate_identity" => certificate_identity(identity.product_version)
      },
      "tree_sha256" => tree_sha256,
      "inventory" => %{
        "artifact_target" => identity.artifact_target,
        "architecture" => identity.architecture,
        "entries" => entries
      }
    }
  end

  defp public_identity(identity) do
    %{
      "engine_id" => identity.engine_id,
      "product_version" => identity.product_version,
      "build_id" => identity.build_id,
      "source_commit" => identity.source_commit,
      "distribution_identity" => identity.distribution_identity,
      "artifact_target" => identity.artifact_target,
      "architecture" => identity.architecture
    }
  end

  defp public_protocols(protocols) when is_map(protocols) do
    with {:ok, management} <- public_range(Map.get(protocols, :management)),
         {:ok, realtime} <- public_range(Map.get(protocols, :realtime)),
         true <- Enum.sort(Map.keys(protocols)) == [:management, :realtime] do
      {:ok, %{"management" => management, "realtime" => realtime}}
    else
      _failure -> {:error, :invalid_protocol_metadata}
    end
  end

  defp public_protocols(_protocols), do: {:error, :invalid_protocol_metadata}

  defp public_range(%{
         current_version: current,
         minimum_version: minimum,
         maximum_version: maximum
       })
       when is_integer(current) and is_integer(minimum) and is_integer(maximum) and
              minimum > 0 and minimum <= current and current <= maximum do
    {:ok,
     %{
       "current_version" => current,
       "minimum_version" => minimum,
       "maximum_version" => maximum
     }}
  end

  defp public_range(_range), do: {:error, :invalid_protocol_metadata}

  defp certificate_identity(version),
    do: "#{@workflow_identity}@refs/tags/v#{version}"

  defp write_file(opts) do
    case Keyword.get(opts, :write_file, &File.write/3) do
      writer when is_function(writer, 3) -> {:ok, writer}
      _invalid -> {:error, :invalid_manifest_writer}
    end
  end

  defp write_atomic(root, contents, writer) do
    destination = Path.join(root, @filename)

    temporary =
      Path.join(
        Path.dirname(root),
        ".#{Path.basename(root)}-manifest-#{System.unique_integer([:positive, :monotonic])}.tmp"
      )

    case writer.(temporary, contents, [:binary]) do
      :ok -> chmod_manifest(temporary, destination)
      {:error, reason} -> cleanup_initial_write(temporary, {:manifest_write_failed, reason})
      invalid -> cleanup_initial_write(temporary, {:invalid_manifest_writer_result, invalid})
    end
  end

  defp chmod_manifest(temporary, destination) do
    case File.chmod(temporary, 0o644) do
      :ok -> rename_manifest(temporary, destination)
      {:error, reason} -> cleanup_failed_write(temporary, {:manifest_chmod_failed, reason})
    end
  end

  defp rename_manifest(temporary, destination) do
    case File.rename(temporary, destination) do
      :ok -> :ok
      {:error, reason} -> cleanup_failed_write(temporary, {:manifest_rename_failed, reason})
    end
  end

  defp cleanup_initial_write(temporary, failure) do
    case File.rm(temporary) do
      :ok -> {:error, failure}
      {:error, :enoent} -> {:error, failure}
      {:error, reason} -> {:error, {:manifest_cleanup_failed, failure, reason}}
    end
  end

  defp cleanup_failed_write(temporary, failure) do
    case File.rm(temporary) do
      :ok -> {:error, failure}
      {:error, reason} -> {:error, {:manifest_cleanup_failed, failure, reason}}
    end
  end
end
