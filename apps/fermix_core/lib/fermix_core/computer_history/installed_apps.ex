defmodule FermixCore.ComputerHistory.InstalledApps do
  @moduledoc """
  Enumerates installed macOS applications as `%{name, bundle_id}` for the setup
  app-allowlist picker (MILESTONE_32 §22.7). Walks the standard application
  directories and reads each bundle's `CFBundleIdentifier` from `Info.plist` via
  `plutil` — Spotlight-independent and deterministic, so it never depends on the
  index being built. macOS-only: returns `[]` on every other platform (the picker
  only renders on macOS).

  `dirs`, `bundle_id_reader`, and `macos?` are injectable so tests run
  hermetically against fixture bundles rather than the host's real applications.
  """

  require Logger

  @system_app_dirs [
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities"
  ]

  # Bound the walk and each bundle read so a pathological home never wedges the
  # setup process (Code Rule 2).
  @max_apps 1000
  @read_timeout_ms 2_000

  @type app :: %{name: String.t(), bundle_id: String.t()}

  @doc """
  All installed apps as `%{name, bundle_id}`, deduped by bundle id and sorted by
  name (case-insensitive). `[]` off macOS. Options (for tests): `:dirs`,
  `:bundle_id_reader` (a `path -> bundle_id | nil` fun), `:macos?`.
  """
  @spec list(keyword()) :: [app()]
  def list(opts \\ []) when is_list(opts) do
    if Keyword.get(opts, :macos?, macos?()) do
      collect(app_dirs(opts), reader(opts))
    else
      []
    end
  end

  defp app_dirs(opts), do: Keyword.get(opts, :dirs, default_dirs())
  defp default_dirs, do: @system_app_dirs ++ [Path.expand("~/Applications")]
  defp reader(opts), do: Keyword.get(opts, :bundle_id_reader, &read_bundle_id/1)

  defp collect(dirs, reader) do
    dirs
    |> Enum.flat_map(&app_bundles/1)
    |> Enum.take(@max_apps)
    |> Task.async_stream(fn path -> {app_name(path), reader.(path)} end,
      max_concurrency: 8,
      timeout: @read_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(&stream_result/1)
    |> Enum.uniq_by(& &1.bundle_id)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp stream_result({:ok, {name, bundle}}) when is_binary(bundle) and bundle != "",
    do: [%{name: name, bundle_id: bundle}]

  defp stream_result(_other), do: []

  # `.app` bundles directly in `dir`, plus those one level down (vendor folders like
  # `/Applications/Adobe …/`). One level only — bounded, and deep recursion into a
  # bundle's own `Contents/` is both pointless and slow.
  defp app_bundles(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &classify_entry(dir, &1))
      {:error, _reason} -> []
    end
  end

  defp classify_entry(dir, entry) do
    path = Path.join(dir, entry)

    cond do
      String.ends_with?(entry, ".app") -> [path]
      File.dir?(path) -> nested_app_bundles(path)
      true -> []
    end
  end

  defp nested_app_bundles(subdir) do
    case File.ls(subdir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".app"))
        |> Enum.map(&Path.join(subdir, &1))

      {:error, _reason} ->
        []
    end
  end

  # The Finder-visible name is the bundle's filename without `.app`.
  defp app_name(path), do: Path.basename(path, ".app")

  # `plutil -extract CFBundleIdentifier raw` prints the bare bundle id. A bundle
  # missing the key (or an unreadable/absent plist) exits non-zero → nil, so that
  # single app is skipped rather than failing the whole enumeration.
  defp read_bundle_id(app_path) do
    plist = Path.join([app_path, "Contents", "Info.plist"])

    case System.cmd("plutil", ["-extract", "CFBundleIdentifier", "raw", "-o", "-", plist],
           stderr_to_stdout: true
         ) do
      {out, 0} -> out |> String.trim() |> presence()
      {_out, _code} -> nil
    end
  rescue
    error in ErlangError ->
      Logger.debug("installed_apps: plutil unavailable for #{app_path}: #{inspect(error)}")
      nil
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp macos?, do: :os.type() == {:unix, :darwin}
end
