defmodule FermixCore.Release.NativeLibraries do
  @moduledoc """
  The Burrito patch post-step that makes every native library of the target's
  runtime the one the release loads.

  Burrito's copy step puts each library of the unpacked runtime at the same
  path in the release, such as `lib/asn1-5.4.3/priv/lib/asn1rt_nif.so`. That is
  the right folder only while the release's app has the runtime's version.
  When the build machine's OTP is newer (`FermixCore.Release.NativeRuntime`),
  the release loads `lib/asn1-5.4.3.1`, which still holds the build machine's
  library, built for that machine alone, and Burrito's copy sits in a folder
  nothing loads. `public_key` decodes every certificate through that library,
  so a release shipped like that fails every TLS connection anywhere else.

  This step copies each runtime library into the folder of the same app the
  release loads, removes the folder Burrito's copy created, and then proves the
  result: every library the runtime carries is, byte for byte, the one in the
  release's folder for that app. A release holding two versions of one app, and
  a runtime that was never unpacked, are refused by name. A library only the
  build machine's OTP carries (`crypto_callback.so`) is left as Burrito leaves it.

  Burrito is a dependency of the umbrella root rather than of this app, so
  nothing here names a `Burrito.*` module. `execute/1` is Burrito's step
  contract and the build context is matched as the plain map it is.
  """

  @native_glob "**/*.{so,dll}"
  @app_folder ~r/^(?<app>[a-z][a-z0-9_]*)-(?<vsn>[0-9][0-9A-Za-z.]*)$/

  @doc "Burrito's step entry point, run after the patch phase."
  @spec execute(map()) :: map()
  def execute(context) when is_map(context), do: run(context)

  @doc "The step."
  @spec run(map()) :: map()
  def run(%{target: %{erts_source: {:local_unpacked, path: erts}}, work_dir: work_dir} = context)
      when is_binary(erts) and is_binary(work_dir) do
    runtime_lib = runtime_lib!(erts)
    release_lib = Path.join(work_dir, "lib")

    for {app, runtime_folder, libraries} <- runtime_apps(runtime_lib) do
      case release_folders(release_lib, app) do
        [] ->
          :not_in_release

        [folder] ->
          place!(runtime_lib, runtime_folder, release_lib, folder, libraries)

        folders ->
          raise "the release holds #{Enum.join(folders, " and ")}: two versions of #{app}"
      end
    end

    context
  end

  def run(%{target: %{erts_source: source}}) do
    raise "the native libraries step needs the target's runtime unpacked, and this target " <>
            "names #{inspect(source)}"
  end

  # Where the unpacked tarball keeps its apps: `lib` at its top, or one folder
  # down (`otp_x86_64_linux_28.5.0.6/lib`), the folder Burrito's copy reads.
  defp runtime_lib!(erts) do
    case Path.wildcard(Path.join(erts, "lib")) ++ Path.wildcard(Path.join(erts, "*/lib")) do
      [lib] ->
        lib

      found ->
        raise "expected one lib folder in the unpacked runtime #{erts}, found #{inspect(found)}"
    end
  end

  defp runtime_apps(runtime_lib) do
    runtime_lib
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn folder ->
      libraries = native_libraries(Path.join(runtime_lib, folder))

      case {app_name(folder), libraries} do
        {nil, _} -> []
        {_app, []} -> []
        {app, libraries} -> [{app, folder, libraries}]
      end
    end)
  end

  defp native_libraries(dir) do
    dir
    |> Path.join(@native_glob)
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  # The release's own folders for an app are the ones holding its code: a
  # folder Burrito's copy created holds only libraries.
  defp release_folders(release_lib, app) do
    release_lib
    |> File.ls!()
    |> Enum.filter(&(app_name(&1) == app and File.dir?(Path.join([release_lib, &1, "ebin"]))))
    |> Enum.sort()
  end

  defp app_name(folder) do
    case Regex.named_captures(@app_folder, folder) do
      %{"app" => app} -> app
      nil -> nil
    end
  end

  defp place!(runtime_lib, folder, release_lib, folder, libraries) do
    prove!(runtime_lib, folder, release_lib, folder, libraries)
  end

  defp place!(runtime_lib, runtime_folder, release_lib, release_folder, libraries) do
    Enum.each(libraries, fn relative ->
      destination = Path.join([release_lib, release_folder, relative])
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(Path.join([runtime_lib, runtime_folder, relative]), destination)
    end)

    remove_stray_copy!(Path.join(release_lib, runtime_folder))
    prove!(runtime_lib, runtime_folder, release_lib, release_folder, libraries)

    IO.puts(
      "fermix: the target runtime's #{runtime_folder} libraries now sit in #{release_folder}, " <>
        "the folder the release loads"
    )
  end

  defp remove_stray_copy!(stray) do
    if File.dir?(stray) and not File.dir?(Path.join(stray, "ebin")), do: File.rm_rf!(stray)
  end

  defp prove!(runtime_lib, runtime_folder, release_lib, release_folder, libraries) do
    Enum.each(libraries, fn relative ->
      expected = File.read!(Path.join([runtime_lib, runtime_folder, relative]))
      loaded = Path.join([release_lib, release_folder, relative])

      if File.read(loaded) != {:ok, expected} do
        raise "lib/#{release_folder}/#{relative} is not the target runtime's " <>
                "#{runtime_folder}/#{relative}: a library built for the build machine loads " <>
                "only there"
      end
    end)
  end
end
