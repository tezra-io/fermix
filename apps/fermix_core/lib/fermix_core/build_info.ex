defmodule FermixCore.BuildInfo do
  @moduledoc """
  Immutable identity compiled into one Fermix engine artifact.

  Published builds provide the `FERMIX_BUILD_*` inputs while compiling. They are
  read only by the compiler and become BEAM literals. Runtime environment,
  executable paths, package-manager state, and the current checkout are never
  consulted when reporting artifact identity.
  """

  alias FermixCore.Management.Protocol, as: ManagementProtocol
  alias FermixCore.Realtime.Protocol, as: RealtimeProtocol

  @engine_id "fermix-core"
  @product_version Mix.Project.config() |> Keyword.fetch!(:version) |> to_string()
  @build_id System.get_env("FERMIX_BUILD_ID")
  @source_commit System.get_env("FERMIX_BUILD_SOURCE_COMMIT")
  @distribution_identity System.get_env("FERMIX_BUILD_DISTRIBUTION") || "standalone"
  @artifact_target System.get_env("FERMIX_BUILD_TARGET")
  @build_id_pattern ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/
  @source_commit_pattern ~r/^[0-9a-f]{40}$/i
  @target_architectures %{
    "macos_aarch64" => "arm64",
    "macos_x86_64" => "x86_64",
    "linux_aarch64" => "arm64",
    "linux_x86_64" => "x86_64"
  }
  @app_targets Map.take(@target_architectures, ["macos_aarch64", "macos_x86_64"])

  unless @distribution_identity in ["standalone", "macos_app"] do
    raise "invalid FERMIX_BUILD_DISTRIBUTION: #{inspect(@distribution_identity)}"
  end

  if @artifact_target && !Map.has_key?(@target_architectures, @artifact_target) do
    raise "invalid FERMIX_BUILD_TARGET: #{inspect(@artifact_target)}"
  end

  if @distribution_identity == "macos_app" do
    unless is_binary(@build_id) and Regex.match?(@build_id_pattern, @build_id) do
      raise "FERMIX_BUILD_ID is required for macos_app builds"
    end

    unless is_binary(@source_commit) and Regex.match?(@source_commit_pattern, @source_commit) do
      raise "FERMIX_BUILD_SOURCE_COMMIT must be a full commit for macos_app builds"
    end

    unless Map.has_key?(@app_targets, @artifact_target) do
      raise "FERMIX_BUILD_TARGET must name a macOS architecture for macos_app builds"
    end
  end

  @architecture Map.get_lazy(@target_architectures, @artifact_target, fn ->
                  :system_architecture
                  |> :erlang.system_info()
                  |> to_string()
                  |> then(fn
                    "aarch64" <> _rest -> "arm64"
                    "arm64" <> _rest -> "arm64"
                    "x86_64" <> _rest -> "x86_64"
                    other -> other
                  end)
                end)

  @type identity :: %{
          engine_id: String.t(),
          product_version: String.t(),
          build_id: String.t() | nil,
          source_commit: String.t() | nil,
          distribution_identity: String.t(),
          artifact_target: String.t() | nil,
          architecture: String.t()
        }

  @doc "Returns the engine artifact identity compiled into this BEAM build."
  @spec identity() :: identity()
  def identity do
    %{
      engine_id: @engine_id,
      product_version: @product_version,
      build_id: @build_id,
      source_commit: @source_commit,
      distribution_identity: @distribution_identity,
      artifact_target: @artifact_target,
      architecture: @architecture
    }
  end

  @doc "Returns the immutable identity with stable public string keys."
  @spec public_identity() :: map()
  def public_identity do
    %{
      "engine_id" => @engine_id,
      "product_version" => @product_version,
      "build_id" => @build_id,
      "source_commit" => @source_commit,
      "distribution_identity" => @distribution_identity,
      "artifact_target" => @artifact_target,
      "architecture" => @architecture
    }
  end

  @doc "Returns the product version compiled into this engine."
  @spec product_version() :: String.t()
  def product_version, do: @product_version

  @doc "Returns the immutable distribution identity."
  @spec distribution_identity() :: String.t()
  def distribution_identity, do: @distribution_identity

  @doc "Whether this artifact is an app-owned macOS engine."
  @spec app_engine?() :: boolean()
  def app_engine?, do: @distribution_identity == "macos_app"

  @doc "Returns management and Realtime ranges from their wire authorities."
  @spec protocols() :: map()
  def protocols do
    %{
      management: protocol_metadata(ManagementProtocol),
      realtime: protocol_metadata(RealtimeProtocol)
    }
  end

  @doc "Validates identity fields required in a published macOS app engine."
  @spec validate_app_engine(map()) :: :ok | {:error, {:invalid_build_info, atom()}}
  def validate_app_engine(identity) when is_map(identity) do
    with :ok <- exact_fields(identity),
         :ok <- valid_string(identity, :engine_id),
         :ok <- valid_string(identity, :product_version),
         :ok <- valid_pattern(identity, :build_id, @build_id_pattern),
         :ok <- valid_pattern(identity, :source_commit, @source_commit_pattern),
         :ok <- valid_distribution(identity),
         :ok <- valid_target(identity),
         :ok <- matching_architecture(identity) do
      :ok
    end
  end

  def validate_app_engine(_identity), do: invalid(:identity)

  @doc "Validates the identity compiled into the current app-engine build."
  @spec validate_current_app_engine() :: :ok | {:error, {:invalid_build_info, atom()}}
  def validate_current_app_engine, do: validate_app_engine(identity())

  defp protocol_metadata(module) do
    {minimum, maximum} = module.supported_version_range()

    %{
      current_version: module.protocol_version(),
      minimum_version: minimum,
      maximum_version: maximum
    }
  end

  defp exact_fields(identity) do
    expected = ~w(
      architecture artifact_target build_id distribution_identity engine_id
      product_version source_commit
    )a

    if Enum.sort(Map.keys(identity)) == Enum.sort(expected), do: :ok, else: invalid(:identity)
  end

  defp valid_string(identity, field) do
    case Map.get(identity, field) do
      value when is_binary(value) and byte_size(value) in 1..256 -> :ok
      _value -> invalid(field)
    end
  end

  defp valid_pattern(identity, field, pattern) do
    case Map.get(identity, field) do
      value when is_binary(value) ->
        if Regex.match?(pattern, value), do: :ok, else: invalid(field)

      _value ->
        invalid(field)
    end
  end

  defp valid_distribution(%{distribution_identity: "macos_app"}), do: :ok
  defp valid_distribution(_identity), do: invalid(:distribution_identity)

  defp valid_target(identity) do
    if Map.has_key?(@app_targets, Map.get(identity, :artifact_target)),
      do: :ok,
      else: invalid(:artifact_target)
  end

  defp matching_architecture(identity) do
    expected = Map.get(@app_targets, identity.artifact_target)
    if identity.architecture == expected, do: :ok, else: invalid(:architecture)
  end

  defp invalid(field), do: {:error, {:invalid_build_info, field}}
end
