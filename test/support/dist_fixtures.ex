defmodule FermixTestSupport.DistFixtures do
  @moduledoc """
  Shared builders for plugin-distribution tests: a Registry-valid plugin
  tarball, a catalog-index plugin entry wired to `DistFetcherStub`, and an
  index-file writer. Used by the installer and CLI dist-verb suites so both
  exercise identical artifacts.
  """

  alias FermixTestSupport.DistFetcherStub

  @doc """
  Build a fixture plugin `.tar.gz` (manifest at the archive root) whose
  default manifest passes `Registry.decode_manifest/2` in full. Returns
  `{tgz_path, sha256_hex}`.

  Options: `:manifest_name`, `:manifest_version`, `:manifest_extra` (merged
  over the default), `:extra_members` (extra `{charlist_path, content}` tar
  members, e.g. to inject boundary violations).
  """
  @spec build_tarball(Path.t(), String.t(), String.t(), keyword()) :: {Path.t(), String.t()}
  def build_tarball(fixtures, name, version, opts \\ []) do
    manifest =
      %{
        "schema_version" => 2,
        "name" => Keyword.get(opts, :manifest_name, name),
        "display_name" => name,
        "description" => "#{name} test plugin",
        "category" => "developer",
        "version" => Keyword.get(opts, :manifest_version, version),
        "plugin_api" => 2,
        "min_core_version" => "0.1.0",
        "auth" => %{"type" => "none"},
        "tools" => []
      }
      |> Map.merge(Keyword.get(opts, :manifest_extra, %{}))

    base = [
      {~c"plugin.json", Jason.encode!(manifest)},
      {~c"skills/#{name}/SKILL.md", "---\nname: #{name}\n---\n"}
    ]

    members = base ++ Keyword.get(opts, :extra_members, [])
    tgz = Path.join(fixtures, "#{name}-#{version}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(tgz), members, [:compressed])
    sha = :sha256 |> :crypto.hash(File.read!(tgz)) |> Base.encode16(case: :lower)
    {tgz, sha}
  end

  @doc """
  Wire `DistFetcherStub` to serve `tgz` (plus sig/cert fixtures) for
  `name@version` and return the catalog-index plugin entry map.

  Options: `:yanked`, `:plugin_api`, `:target`, `:index_sha`, `:latest`.
  """
  @spec wire(Path.t(), String.t(), String.t(), Path.t(), String.t(), keyword()) :: map()
  def wire(fixtures, name, version, tgz, sha, opts \\ []) do
    base = "https://example.com/#{name}-#{version}"
    sig = Path.join(fixtures, "#{name}-#{version}.sig")
    cert = Path.join(fixtures, "#{name}-#{version}.pem")
    File.write!(sig, "sig")
    File.write!(cert, "cert")

    DistFetcherStub.set(base <> ".tar.gz", {:copy, tgz})
    DistFetcherStub.set(base <> ".sig", {:copy, sig})
    DistFetcherStub.set(base <> ".pem", {:copy, cert})

    %{
      "name" => name,
      "display_name" => name,
      "category" => "developer",
      "auth_type" => "none",
      "rails" => ["http"],
      "latest" => Keyword.get(opts, :latest, version),
      "yanked" => Keyword.get(opts, :yanked, []),
      "versions" => [
        %{
          "version" => version,
          "published_at" => "2026-06-07T00:00:00Z",
          "min_core_version" => "0.1.0",
          "plugin_api" => Keyword.get(opts, :plugin_api, 2),
          "artifacts" => [
            %{
              "target" => Keyword.get(opts, :target, "any"),
              "url" => base <> ".tar.gz",
              "sha256" => Keyword.get(opts, :index_sha, sha),
              "sig_url" => base <> ".sig",
              "cert_url" => base <> ".pem"
            }
          ]
        }
      ]
    }
  end

  @doc "Write an index file containing `plugins` entries. Option: `:generated_at`."
  @spec write_index(Path.t(), [map()], keyword()) :: Path.t()
  def write_index(path, plugins, opts \\ []) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        schema_version: 1,
        generated_at: Keyword.get(opts, :generated_at, "2026-06-07T00:00:00Z"),
        plugins: plugins
      })
    )

    path
  end
end
