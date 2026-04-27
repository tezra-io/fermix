defmodule Fermix.CLI.Upgrade.Manifest do
  @moduledoc """
  Fetches and parses the signed-release manifest emitted by
  `scripts/release/build_releases_json.sh` and attached to each
  GitHub Release as `releases.json`.

  Schema is documented inline in that script. This module is
  defensive about missing keys but does **not** silently degrade —
  unrecognized shapes return `{:error, _}` so the caller surfaces
  the failure.
  """

  @manifest_url "https://github.com/tezra-io/fermix/releases/latest/download/releases.json"

  @type artifact :: %{
          target: String.t(),
          url: String.t(),
          sha256: String.t(),
          sig_url: String.t(),
          cert_url: String.t()
        }

  @type release :: %{
          version: String.t(),
          published_at: String.t(),
          artifacts: [artifact()]
        }

  @type t :: %{
          schema_version: pos_integer(),
          latest: String.t(),
          releases: [release()]
        }

  @spec default_url() :: String.t()
  def default_url, do: @manifest_url

  @spec fetch(keyword()) :: {:ok, t()} | {:error, term()}
  def fetch(opts \\ []) do
    url = Keyword.get(opts, :url, @manifest_url)
    req_options = Keyword.get(opts, :req_options, [])

    case Req.get(url, req_options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> normalize(body)
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> decode(body)
      {:ok, %Req.Response{status: status}} -> {:error, {:manifest_http_status, status}}
      {:error, reason} -> {:error, {:manifest_fetch_failed, reason}}
    end
  end

  @spec select_artifact(release(), {atom(), atom()}) :: {:ok, artifact()} | {:error, term()}
  def select_artifact(%{artifacts: artifacts}, target) do
    target_str = target_string(target)

    case Enum.find(artifacts, &(&1.target == target_str)) do
      nil -> {:error, {:no_artifact_for_target, target_str}}
      artifact -> {:ok, artifact}
    end
  end

  @spec latest_release(t()) :: {:ok, release()} | {:error, term()}
  def latest_release(%{latest: latest, releases: releases}) do
    case Enum.find(releases, &(&1.version == latest)) do
      nil -> {:error, {:latest_not_in_releases, latest}}
      release -> {:ok, release}
    end
  end

  @spec compare_versions(String.t(), String.t()) :: :lt | :eq | :gt | {:error, term()}
  def compare_versions(current, latest) do
    with {:ok, c} <- Version.parse(current),
         {:ok, l} <- Version.parse(latest) do
      Version.compare(c, l)
    else
      :error -> {:error, {:invalid_version, current, latest}}
    end
  end

  @spec target_for_host() :: {:ok, {atom(), atom()}} | {:error, term()}
  def target_for_host do
    with {:ok, os} <- detect_os(),
         {:ok, arch} <- detect_arch() do
      {:ok, {os, arch}}
    end
  end

  defp detect_os do
    case :os.type() do
      {:unix, :darwin} -> {:ok, :macos}
      {:unix, :linux} -> {:ok, :linux}
      other -> {:error, {:unsupported_os, other}}
    end
  end

  defp detect_arch do
    case :erlang.system_info(:system_architecture) |> List.to_string() do
      "aarch64" <> _ -> {:ok, :aarch64}
      "arm64" <> _ -> {:ok, :aarch64}
      "x86_64" <> _ -> {:ok, :x86_64}
      "amd64" <> _ -> {:ok, :x86_64}
      other -> {:error, {:unsupported_arch, other}}
    end
  end

  defp target_string({:macos, :aarch64}), do: "macos-aarch64"
  defp target_string({:macos, :x86_64}), do: "macos-x86_64"
  defp target_string({:linux, :aarch64}), do: "linux-aarch64"
  defp target_string({:linux, :x86_64}), do: "linux-x86_64"

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> normalize(decoded)
      {:error, reason} -> {:error, {:manifest_invalid_json, reason}}
    end
  end

  defp normalize(%{"schema_version" => schema, "latest" => latest, "releases" => releases})
       when is_integer(schema) and is_binary(latest) and is_list(releases) do
    {:ok,
     %{
       schema_version: schema,
       latest: latest,
       releases: Enum.map(releases, &normalize_release/1)
     }}
  end

  defp normalize(_other), do: {:error, :manifest_schema_mismatch}

  defp normalize_release(%{"version" => version, "artifacts" => artifacts} = release)
       when is_binary(version) and is_list(artifacts) do
    %{
      version: version,
      published_at: Map.get(release, "published_at", ""),
      artifacts: Enum.map(artifacts, &normalize_artifact/1)
    }
  end

  defp normalize_artifact(%{
         "target" => target,
         "url" => url,
         "sha256" => sha256,
         "sig_url" => sig_url,
         "cert_url" => cert_url
       }) do
    %{target: target, url: url, sha256: sha256, sig_url: sig_url, cert_url: cert_url}
  end
end
