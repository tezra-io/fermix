defmodule Mix.Tasks.Fermix.Cues.Funnel do
  @shortdoc "Mounts or removes one webhook source's path on Tailscale Funnel for the current FERMIX_HOME"

  @moduledoc """
  Puts one webhook source on the internet through Tailscale Funnel (M60 §6.5),
  before the app has a surface for it:

      mix fermix.cues.funnel <source_ref> [--apply]
      mix fermix.cues.funnel <source_ref> --remove [--apply]

  It prints the exact command

      tailscale funnel --bg --set-path=/cues/hooks/<ref>/<random> http://127.0.0.1:<door port>/cues/hooks/<ref>/<random>

  (the same path on both sides, because Tailscale strips the mount point
  before proxying) and the `https://<machine>.<tailnet>.ts.net/...` URL to
  paste into the service, and runs the command only with `--apply`. The path
  is always the source's `/cues/hooks/<ref>/<random>`, never `/`.

  Before anything else it reads `tailscale status --json` (Tailscale must be
  running and Funnel allowed for this machine) and `tailscale funnel status
  --json`. Funnel is allowed per host and port, not per path, so it refuses to
  add a mount while port 443 carries one Fermix did not make: a handler that
  is not a `/cues/hooks/<ref>/<random>` path proxied to the same path on
  `127.0.0.1`, or a raw TCP forward, in the background config or a foreground
  session. A source already mounted at its path is left alone; one mounted at
  an older path must be removed first.

  `--remove` removes every mount of the source found in the Funnel status
  (`tailscale funnel --https=<port> --set-path=<path> off`), so it works after
  the URL changed or the source left the config. Disabling or removing a
  source in settings does not remove its mount; this does.

  It reads the current `FERMIX_HOME`'s config without resolving any other
  secret and starts no daemon tree. The source's URL is made
  (`Cues.Webhook.ensure_path_secret/2`) when a new webhook source is saved on
  the setup page, by its Generate URL, or by the Mac app's Copy URL.
  """

  use Mix.Task

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.Webhook
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter

  @usage "usage: mix fermix.cues.funnel <source_ref> [--remove] [--apply]"
  @funnel_port "443"
  @hook_path ~r|\A/cues/hooks/[a-z0-9][a-z0-9-]{0,63}/[A-Za-z0-9_-]{1,128}\z|
  @loopback_target ~r|\Ahttp://127\.0\.0\.1:\d{1,5}(/.*)\z|
  @funnel_caps ["funnel", "https://tailscale.com/cap/funnel"]
  @funnel_cap_prefix "https://tailscale.com/cap/funnel"
  @not_installed "tailscale is not installed or not on PATH; install Tailscale and its " <>
                   "command-line tool, then try again."

  @type runner :: ([String.t()] -> {String.t(), non_neg_integer()} | {:error, :not_found})

  @impl Mix.Task
  def run(args) do
    # Compiled code only: `app.config` would run `runtime.exs`, which resolves
    # every secret the home holds, and nothing here needs them.
    Mix.Task.run("compile")
    execute(args)
  end

  @doc false
  @spec execute([String.t()], keyword()) :: :ok
  def execute(args, opts \\ []) when is_list(args) and is_list(opts) do
    runner = Keyword.get(opts, :runner, &tailscale/1)

    case parse_args!(args) do
      {ref, :mount, apply?} -> mount(ref, apply?, runner)
      {ref, :remove, apply?} -> remove(ref, apply?, runner)
    end
  end

  defp parse_args!(args) do
    case OptionParser.parse(args, strict: [apply: :boolean, remove: :boolean]) do
      {flags, [ref], []} ->
        mode = if Keyword.get(flags, :remove, false), do: :remove, else: :mount
        {valid_ref!(ref), mode, Keyword.get(flags, :apply, false)}

      _other ->
        Mix.raise(@usage)
    end
  end

  defp valid_ref!(ref) do
    if CuesConfig.valid_name?(ref),
      do: ref,
      else: Mix.raise("#{inspect(ref)} is not a source name. #{@usage}")
  end

  # --- mount -------------------------------------------------------------------

  defp mount(ref, apply?, runner) do
    {port, random} = source_url!(ref)
    path = Webhook.path(ref, random)
    target = "http://127.0.0.1:#{port}" <> path
    url = "https://#{tailnet_host!(runner)}#{path}"
    mounts = funnel_mounts!(runner)
    check_port!(mounts)

    case Enum.filter(mounts, &own_mount?(&1, ref)) do
      [] ->
        add_mount(["funnel", "--bg", "--set-path=" <> path, target], url, apply?, runner)

      [%{path: ^path, target: ^target}] ->
        Mix.shell().info("Source #{ref} is already mounted at #{url}")

      [other | _rest] ->
        Mix.raise(
          "Source #{ref} already has a Funnel mount at #{other.path}; remove it first with " <>
            "mix fermix.cues.funnel #{ref} --remove --apply"
        )
    end

    :ok
  end

  defp add_mount(args, url, apply?, runner) do
    Mix.shell().info("The Funnel mount for this source:\n  " <> command_line(args))

    if apply? do
      print_output(call!(runner, args))
      Mix.shell().info("Mounted. Paste this URL into the service: #{url}")
    else
      Mix.shell().info("Its webhook URL will be: #{url}")
      Mix.shell().info("Nothing was changed; run again with --apply to mount it.")
    end
  end

  defp source_url!(ref) do
    snapshot =
      case ConfigStore.load_runtime_config(resolve_secrets: false, supervised: false) do
        {:ok, snapshot} ->
          snapshot

        {:error, reason} ->
          Mix.raise("config.toml could not be read: #{ConfigStore.load_error_sentence(reason)}")
      end

    cues = Keyword.get(snapshot.fermix_core, :cues, [])
    source = mountable_source!(ref, cues)
    random = read_path_secret!(source, Keyword.get(snapshot.fermix_core, :profile))
    {CuesConfig.door_port(cues), random}
  end

  defp mountable_source!(ref, cues) do
    case CuesConfig.source(ref, cues) do
      {:ok, %{kind: :webhook, enabled?: false}} ->
        Mix.raise("Source #{ref} is disabled; enable it before putting it on Funnel.")

      {:ok, %{kind: :webhook, secrets: %{path_secret: _store}} = source} ->
        source

      {:ok, %{kind: :webhook}} ->
        Mix.raise("Source #{ref} has no URL yet; make it with Generate URL on the setup page.")

      {:ok, %{kind: kind}} ->
        Mix.raise("Source #{ref} is a #{kind} source; only a webhook source goes on Funnel.")

      :error ->
        Mix.raise("There is no source #{ref} in #{ConfigStore.path()}.")
    end
  end

  # A tree-less task has no command host, so the read says `supervised: false`.
  defp read_path_secret!(%{ref: ref, secrets: %{path_secret: store}}, profile) do
    key = {:cue_source, ref, :path_secret}

    case SecretWriter.get(key, store: store, profile: profile, supervised: false) do
      {:ok, random} ->
        random

      {:error, reason} ->
        Mix.raise(
          "The URL of #{ref} could not be read from the #{store} store: #{inspect(reason)}"
        )
    end
  end

  # --- remove ------------------------------------------------------------------

  defp remove(ref, apply?, runner) do
    case runner |> funnel_mounts!() |> Enum.filter(&own_mount?(&1, ref)) do
      [] -> Mix.shell().info("Source #{ref} has no Funnel mount.")
      mounts -> Enum.each(mounts, &remove_mount(&1, apply?, runner))
    end

    :ok
  end

  defp remove_mount(mount, apply?, runner) do
    args = ["funnel", "--https=#{mount.port}", "--set-path=" <> mount.path, "off"]
    Mix.shell().info("Removing the Funnel mount at #{mount.path}:\n  " <> command_line(args))

    if apply? do
      print_output(call!(runner, args))
      Mix.shell().info("Removed.")
    else
      Mix.shell().info("Nothing was changed; run again with --apply to remove it.")
    end
  end

  # --- tailscale status --------------------------------------------------------

  defp tailnet_host!(runner) do
    status = read_json!(runner, ["status", "--json"])
    self_status = map_at(status, "Self")

    case Map.get(status, "BackendState") do
      "Running" ->
        :ok

      state ->
        Mix.raise("Tailscale is not running (#{state || "no state"}); start it, then try again.")
    end

    unless funnel_allowed?(self_status) do
      Mix.raise(
        "Funnel is not allowed for this machine in your tailnet; grant it the funnel " <>
          "attribute in the tailnet policy, then try again."
      )
    end

    dns_name!(self_status)
  end

  defp funnel_allowed?(self_status) do
    caps =
      Map.keys(map_at(self_status, "CapMap")) ++ List.wrap(Map.get(self_status, "Capabilities"))

    Enum.any?(caps, fn cap ->
      is_binary(cap) and (cap in @funnel_caps or String.starts_with?(cap, @funnel_cap_prefix))
    end)
  end

  defp dns_name!(self_status) do
    case Map.get(self_status, "DNSName") do
      name when is_binary(name) and name != "" ->
        String.trim_trailing(name, ".")

      _none ->
        Mix.raise("Tailscale gives this machine no DNS name; turn on MagicDNS for the tailnet.")
    end
  end

  # Every mount in the background config and in foreground sessions, as
  # `%{port, path, target}`; a raw TCP forward has no path.
  defp funnel_mounts!(runner) do
    config = read_json!(runner, ["funnel", "status", "--json"])
    sessions = config |> map_at("Foreground") |> Map.values()
    Enum.flat_map([config | sessions], &serve_mounts/1)
  end

  defp serve_mounts(%{} = config) do
    web =
      for {host_port, %{"Handlers" => %{} = handlers}} <- map_at(config, "Web"),
          {path, handler} <- handlers,
          do: %{port: port_of(host_port), path: path, target: handler_target(handler)}

    tcp =
      for {port, %{"TCPForward" => forward}} <- map_at(config, "TCP"),
          is_binary(forward) and forward != "",
          do: %{port: port, path: nil, target: "TCP to " <> forward}

    web ++ tcp
  end

  defp serve_mounts(_not_a_config), do: []

  defp port_of(host_port), do: host_port |> String.split(":") |> List.last()

  defp handler_target(%{"Proxy" => proxy}) when is_binary(proxy), do: proxy
  defp handler_target(%{"Path" => dir}) when is_binary(dir), do: "files in " <> dir
  defp handler_target(%{"Text" => _text}), do: "a text reply"
  defp handler_target(_other), do: "another handler"

  defp fermix_mount?(%{path: path, target: target}) when is_binary(path) do
    Regex.match?(@hook_path, path) and match?([_url, ^path], Regex.run(@loopback_target, target))
  end

  defp fermix_mount?(_tcp_forward), do: false

  defp own_mount?(mount, ref),
    do: fermix_mount?(mount) and String.starts_with?(mount.path, "/cues/hooks/#{ref}/")

  defp check_port!(mounts) do
    case Enum.find(mounts, &(&1.port == @funnel_port and not fermix_mount?(&1))) do
      nil ->
        :ok

      %{path: nil, target: target} ->
        Mix.raise(
          "This machine's Tailscale forwards port 443 as raw TCP (#{target}). Funnel is " <>
            "allowed per port, not per path, so Fermix will not add its mount there."
        )

      %{path: path, target: target} ->
        Mix.raise(
          "Port 443 of this machine's Tailscale carries a mount Fermix did not make " <>
            "(#{path} -> #{target}). Funnel is allowed per port, not per path, so Fermix will " <>
            "not add its mount there; move that mount to another port or remove it first."
        )
    end
  end

  # --- running tailscale -------------------------------------------------------

  defp read_json!(runner, args) do
    case Jason.decode(call!(runner, args)) do
      {:ok, %{} = decoded} ->
        decoded

      {:ok, nil} ->
        %{}

      _not_an_object ->
        Mix.raise(
          "Fermix could not read `#{command_line(args)}`: it did not answer a JSON object."
        )
    end
  end

  defp call!(runner, args) do
    case runner.(args) do
      {:error, :not_found} ->
        Mix.raise(@not_installed)

      {output, 0} ->
        output

      {output, status} when is_binary(output) and is_integer(status) ->
        Mix.raise("`#{command_line(args)}` failed (exit #{status}): #{String.trim(output)}")
    end
  end

  defp print_output(output) do
    case String.trim(output) do
      "" -> :ok
      text -> Mix.shell().info(text)
    end
  end

  defp command_line(args), do: Enum.join(["tailscale" | args], " ")

  defp map_at(map, key) do
    case Map.get(map, key) do
      %{} = value -> value
      _absent -> %{}
    end
  end

  defp tailscale(args) do
    case System.find_executable("tailscale") do
      nil -> {:error, :not_found}
      executable -> System.cmd(executable, args, stderr_to_stdout: true)
    end
  end
end
