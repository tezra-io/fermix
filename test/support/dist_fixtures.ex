defmodule FermixTestSupport.DistFixtures do
  @moduledoc """
  Shared builders for plugin-distribution tests: a Registry-valid plugin
  tarball, a catalog-index plugin entry wired to `DistFetcherStub`, and an
  index-file writer. Used by the installer and CLI dist-verb suites so both
  exercise identical artifacts.
  """

  alias FermixCore.Plugins.Dist.Archive
  alias FermixCore.Plugins.Dist.Provenance
  alias FermixCore.Plugins.Dist.Store
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

  Options: `:yanked`, `:plugin_api`, `:target`, `:index_sha`, `:latest`,
  `:auth_type`, `:auth_provider`.
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
      "auth_type" => Keyword.get(opts, :auth_type, "none"),
      "auth_provider" => Keyword.get(opts, :auth_provider),
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

  @doc """
  Install a `remote_mcp` plugin the provenance gate will accept.

  A remote manifest is loadable only from an artifact whose publisher signature
  and tree digest re-verify (M27 §9.3), so a test that wants one in the registry
  cannot just drop a `plugin.json` in a dev_local directory — that is refused by
  design. This builds the artifact, installs the tree, retains the evidence, and
  and retains the evidence.

  Deliberately does NOT allow-list the artifact: `DistVerifierStub` denies by
  default, and a caller that wants the plugin to load says so with
  `DistVerifierStub.allow(name, version)`. Allow-listing here would make it
  impossible to test the refusal.
  """
  def install_remote_plugin(root, fixtures, name, version, manifest_extra) do
    {tgz, sha} = build_tarball(fixtures, name, version, manifest_extra: manifest_extra)

    staged = Path.join(Store.paths(root).staging, "#{name}-#{version}")
    :ok = Archive.extract(tgz, staged)
    :ok = Store.install_tree(root, name, version, staged)

    :ok =
      Provenance.retain(root, name, version, %{
        archive: tgz,
        sig: write_fixture(fixtures, "#{name}.sig", "signature"),
        cert: write_fixture(fixtures, "#{name}.pem", "certificate"),
        sha256: sha
      })

    :ok =
      Store.record(root, name, %{
        "version" => version,
        "sha256" => sha,
        "plugin_api" => Map.get(manifest_extra, "plugin_api", 2),
        "min_core_version" => "0.1.0"
      })

    :ok
  end

  defp write_fixture(fixtures, basename, contents) do
    path = Path.join(fixtures, basename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
