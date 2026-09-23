defmodule FermixCore.Browser.Bridge.HostManifest do
  @moduledoc """
  The native-messaging host manifest, and the wrapper script it points at.

  Chrome starts a native-messaging host by running one executable path from a
  JSON manifest in the browser's `NativeMessagingHosts` directory. It passes no
  shell environment and it cannot pass a verb, so the manifest cannot name
  `fermix` directly: `install/3` writes a small wrapper under
  `<FERMIX_HOME>/bin/` that bakes in the home, the launcher, and the manifest
  it belongs to, and the manifest names the wrapper.

  `allowed_origins` in that manifest is what Chrome enforces about which
  extension may connect, and it is the same list the pump re-reads to refuse an
  origin it was not installed for — one file, one list, both sides.

  Every path is derived from an injected base directory, so tests never touch a
  real browser's directory and a second home never writes into the first's.
  """

  alias Fermix.CLI.LauncherPath
  alias FermixCore.Setup.ConfigStore

  @host_name "ai.fermix.bridge"
  @browsers ~w(chrome chromium brave edge)
  @extension_id ~r/^[a-p]{32}$/

  @darwin_dirs %{
    "chrome" => "Google/Chrome/NativeMessagingHosts",
    "chromium" => "Chromium/NativeMessagingHosts",
    "brave" => "BraveSoftware/Brave-Browser/NativeMessagingHosts",
    "edge" => "Microsoft Edge/NativeMessagingHosts"
  }

  @linux_dirs %{
    "chrome" => "google-chrome/NativeMessagingHosts",
    "chromium" => "chromium/NativeMessagingHosts",
    "brave" => "BraveSoftware/Brave-Browser/NativeMessagingHosts",
    "edge" => "microsoft-edge/NativeMessagingHosts"
  }

  @type reason ::
          {:unsupported_browser, String.t()}
          | {:unsupported_os, atom()}
          | {:invalid_extension_id, String.t()}
          | {:unquotable_path, String.t()}
          | {:write_failed, String.t(), term()}
          | {:unreadable_manifest, String.t(), term()}

  @doc "The browsers this bridge can install into."
  @spec browsers() :: [String.t()]
  def browsers, do: @browsers

  @doc "The native-messaging host name, in every manifest and in the extension."
  @spec host_name() :: String.t()
  def host_name, do: @host_name

  @doc """
  Where `browser`'s manifest lives.

  `:base` is the directory the browser profiles hang off — `~/Library/Application
  Support` on macOS, `~/.config` on Linux — and is injected in tests.
  """
  @spec manifest_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, reason()}
  def manifest_path(browser, opts \\ []) when is_binary(browser) do
    with {:ok, relative} <- relative_dir(browser, os(opts)) do
      {:ok, Path.join([base(opts), relative, @host_name <> ".json"])}
    end
  end

  @doc "The wrapper script `browser`'s manifest points at."
  @spec wrapper_path(String.t(), keyword()) :: String.t()
  def wrapper_path(browser, opts \\ []) when is_binary(browser) do
    Path.join([fermix_home(opts), "bin", "fermix-browser-bridge-#{browser}"])
  end

  @doc """
  Write the wrapper and the manifest for one browser, and say where both went.

  Overwrites an existing pair: an install after an upgrade is how the manifest
  learns the new launcher path, so refusing one would strand it on the old.
  """
  @spec install(String.t(), String.t(), keyword()) ::
          {:ok, %{manifest: String.t(), wrapper: String.t()}} | {:error, reason()}
  def install(browser, extension_id, opts \\ [])
      when is_binary(browser) and is_binary(extension_id) do
    with {:ok, manifest} <- manifest_path(browser, opts),
         :ok <- valid_extension_id(extension_id),
         {:ok, launcher} <- launcher(opts),
         wrapper = wrapper_path(browser, opts),
         :ok <- quotable([launcher, wrapper, manifest, fermix_home(opts)]),
         :ok <- write_wrapper(wrapper, launcher, manifest, opts),
         :ok <- write_manifest(manifest, wrapper, extension_id) do
      {:ok, %{manifest: manifest, wrapper: wrapper}}
    end
  end

  @doc "Remove one browser's manifest and its wrapper. Absent files are already gone."
  @spec uninstall(String.t(), keyword()) ::
          {:ok, %{manifest: String.t(), wrapper: String.t(), removed: boolean()}}
          | {:error, reason()}
  def uninstall(browser, opts \\ []) when is_binary(browser) do
    with {:ok, manifest} <- manifest_path(browser, opts) do
      wrapper = wrapper_path(browser, opts)
      removed = File.exists?(manifest) or File.exists?(wrapper)

      with :ok <- remove(manifest),
           :ok <- remove(wrapper) do
        {:ok, %{manifest: manifest, wrapper: wrapper, removed: removed}}
      end
    end
  end

  @doc """
  What is installed for one browser: the manifest, whether it is there, the
  launcher it names, whether that launcher still exists, and the extensions it
  admits.
  """
  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def status(browser, opts \\ []) when is_binary(browser) do
    with {:ok, manifest} <- manifest_path(browser, opts) do
      {:ok, Map.merge(%{browser: browser, manifest: manifest}, installed(manifest))}
    end
  end

  @doc """
  The origins `manifest` admits — the one list both Chrome and the pump read.
  """
  @spec allowed_origins(String.t()) :: {:ok, [String.t()]} | {:error, reason()}
  def allowed_origins(manifest) when is_binary(manifest) do
    with {:ok, body} <- read(manifest),
         {:ok, decoded} <- decode(manifest, body) do
      case Map.get(decoded, "allowed_origins") do
        list when is_list(list) -> {:ok, origins(list)}
        _absent -> {:error, {:unreadable_manifest, manifest, :no_allowed_origins}}
      end
    end
  end

  # Two files stand between the browser and the daemon — the wrapper the manifest
  # names, and the `fermix` the wrapper execs — and an upgrade or an uninstall
  # can take either. Both are reported, because "installed" with a launcher that
  # is gone is the state that looks fine and works for nobody.
  defp installed(manifest) do
    with {:ok, body} <- read(manifest),
         {:ok, decoded} <- decode(manifest, body) do
      wrapper = normalize_launcher(Map.get(decoded, "path"))

      %{
        installed: true,
        wrapper: wrapper,
        wrapper_exists: is_binary(wrapper) and File.exists?(wrapper),
        launcher: wrapper_launcher(wrapper),
        launcher_exists: exists?(wrapper_launcher(wrapper)),
        origins: origins(Map.get(decoded, "allowed_origins"))
      }
    else
      {:error, _reason} -> not_installed()
    end
  end

  defp not_installed do
    %{
      installed: false,
      wrapper: nil,
      wrapper_exists: false,
      launcher: nil,
      launcher_exists: false,
      origins: []
    }
  end

  # The wrapper is this module's own output, so its one `exec` line is read back
  # rather than guessed at; a wrapper somebody edited by hand reports no
  # launcher instead of a wrong one.
  defp wrapper_launcher(wrapper) when is_binary(wrapper) do
    with {:ok, script} <- File.read(wrapper),
         [_line, launcher] <- Regex.run(~r/exec '([^']+)' browser-bridge/, script) do
      launcher
    else
      _unreadable_or_edited -> nil
    end
  end

  defp wrapper_launcher(_wrapper), do: nil

  defp exists?(path) when is_binary(path), do: File.exists?(path)
  defp exists?(_path), do: false

  defp origins(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp origins(_other), do: []

  defp normalize_launcher(value) when is_binary(value), do: value
  defp normalize_launcher(_value), do: nil

  defp read(manifest) do
    case File.read(manifest) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:unreadable_manifest, manifest, reason}}
    end
  end

  defp decode(manifest, body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _other -> {:error, {:unreadable_manifest, manifest, :not_json}}
    end
  end

  # Chrome starts the host with no shell environment at all, so the home and the
  # verb are baked in here rather than assumed. The manifest path travels too:
  # the pump checks the origin Chrome passes against the very file that
  # launched it.
  defp write_wrapper(wrapper, launcher, manifest, opts) do
    script = """
    #!/bin/sh
    # Written by `fermix browser bridge install`. Do not edit: run install again.
    FERMIX_HOME='#{fermix_home(opts)}'
    export FERMIX_HOME
    exec '#{launcher}' browser-bridge --manifest '#{manifest}' "$@"
    """

    with :ok <- mkdir(Path.dirname(wrapper)),
         :ok <- write(wrapper, script) do
      chmod(wrapper, 0o700)
    end
  end

  defp write_manifest(manifest, wrapper, extension_id) do
    body =
      Jason.encode!(
        %{
          name: @host_name,
          description: "Fermix browser bridge",
          path: wrapper,
          type: "stdio",
          allowed_origins: ["chrome-extension://#{extension_id}/"]
        },
        pretty: true
      )

    with :ok <- mkdir(Path.dirname(manifest)) do
      write(manifest, body <> "\n")
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, dir, reason}}
    end
  end

  defp write(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp relative_dir(browser, :darwin) when browser in @browsers,
    do: {:ok, Map.fetch!(@darwin_dirs, browser)}

  defp relative_dir(browser, :linux) when browser in @browsers,
    do: {:ok, Map.fetch!(@linux_dirs, browser)}

  defp relative_dir(browser, os) when browser in @browsers, do: {:error, {:unsupported_os, os}}
  defp relative_dir(browser, _os), do: {:error, {:unsupported_browser, browser}}

  defp valid_extension_id(id) do
    if Regex.match?(@extension_id, id),
      do: :ok,
      else: {:error, {:invalid_extension_id, id}}
  end

  # The wrapper is a `/bin/sh` script and every path in it is single-quoted, so
  # a path carrying a single quote would end the quoting and change what runs.
  # Refused by name rather than escaped: a home nobody can quote is a home to
  # rename, and a silently rewritten path is worse than no install.
  defp quotable(paths) do
    case Enum.find(paths, &String.contains?(&1, "'")) do
      nil -> :ok
      path -> {:error, {:unquotable_path, path}}
    end
  end

  defp launcher(opts) do
    {:ok, LauncherPath.resolve(opts)}
  rescue
    error in ArgumentError -> {:error, {:write_failed, "fermix", error.message}}
  end

  defp os(opts), do: Keyword.get(opts, :os, host_os())

  defp host_os do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:unix, _other} -> :linux
      {family, _name} -> family
    end
  end

  defp base(opts) do
    Keyword.get_lazy(opts, :base, fn -> default_base(os(opts)) end)
  end

  defp default_base(:darwin), do: Path.join(System.user_home!(), "Library/Application Support")
  defp default_base(_os), do: Path.join(System.user_home!(), ".config")

  defp fermix_home(opts) do
    Keyword.get_lazy(opts, :fermix_home, &ConfigStore.fermix_home/0)
  end
end
