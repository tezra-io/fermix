defmodule FermixCore.Computers.Capabilities.Browser do
  @moduledoc """
  `browser` (M97 §6.4): the browser of a computer of the home, where the
  owner's sign-ins are: its Chrome profiles, the Fermix app's pane on a Mac
  and a tab the owner granted there. Its `browser` switch gates it, at that
  computer.

  The server keeps the `browser` tool's own half (`FermixCore.Browser`: its
  arguments, the owner's approval of a sign-in in the chat, a fill that then
  submits) and sends each request it would hand one of its own profiles here
  instead, as one invocation (`Browser.ComputerRoute`). This computer serves
  it through the code a primary runs (`FermixCore.Browser.serve/6`: a turn's
  lost pane, `Routing`, `ProfileManager` and the profile's own backend), with
  its own browser configuration and network policy, from the process that
  stands for the server's turn here (`Browser.HeldTurn`). Whole requests
  cross, never the browser's own protocol, so a step is one round trip.

  The ops are the requests, named by action (`op/2`); whether one changes
  something is `FermixCore.Browser.mutating?/2`'s answer for its action and
  arguments, so an act that only reads (`get`, `wait`), a cookie or storage
  read and a WebMCP list are ops of their own, read again after a lost
  answer, while a navigation, a click or a sign-in is never sent twice.
  `start`, `stop` and `browser.end` change nothing a second time.

  Bytes cross as the invocation's part, at most 20 MiB: a screenshot, a PDF
  and a download come back (`artifact`), and the server keeps them in its own
  browser folder; an upload's file goes over, into this computer's upload
  folder inside its workspace, where its browser takes it. A result above
  #{256} KiB rides the part too.

  On this computer, before anything runs (`admit/3`): a sign-in only on a
  chat turn (a call's voice is refused, as the server refuses it), a hand-over
  and a profile whose mode is a granted tab only on a turn the owner is in.
  The origin is the server's word, so these guard against a bug there; the
  server checks the same, and more (a shared channel), before it sends.

  Its configuration is the invocation's context (`context.browser`, the
  result of `Desktop.Invoke`'s `:browser`, `local/0` on a running engine),
  never application environment, so a server and a computer run in one test.
  """

  @behaviour FermixCore.Computers.Capability

  require Logger

  alias FermixCore.Browser
  alias FermixCore.Browser.ComputerTurn
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HeldTurn
  alias FermixCore.Browser.Scope
  alias FermixCore.Browser.TurnMarker
  alias FermixCore.Computers.Offers.Browser, as: BrowserOffer
  alias FermixCore.Computers.Origin
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Setup.ConfigStore

  # Each op, the action it serves, and whether it changes something.
  @ops %{
    "browser.doctor" => {"doctor", false},
    "browser.status" => {"status", false},
    "browser.start" => {"start", false},
    "browser.stop" => {"stop", false},
    "browser.open" => {"open", true},
    "browser.navigate" => {"navigate", true},
    "browser.snapshot" => {"snapshot", false},
    "browser.tabs" => {"tabs", false},
    "browser.focus" => {"focus", true},
    "browser.close" => {"close", true},
    "browser.screenshot" => {"screenshot", false},
    "browser.pdf" => {"pdf", false},
    "browser.console" => {"console", false},
    "browser.dialog" => {"dialog", true},
    "browser.cookies" => {"cookies", false},
    "browser.cookies.clear" => {"cookies", true},
    "browser.storage" => {"storage", false},
    "browser.storage.write" => {"storage", true},
    "browser.upload" => {"upload", true},
    "browser.download" => {"download", true},
    "browser.act" => {"act", true},
    "browser.act.read" => {"act", false},
    "browser.webmcp" => {"webmcp", false},
    "browser.webmcp.call" => {"webmcp", true},
    "browser.handover" => {"handover", true},
    "browser.login_for" => {"login_for", false},
    "browser.sign_in" => {"sign_in", true},
    "browser.end" => {nil, false}
  }
  # The actions whose read and write are ops of their own: {read, write}.
  @split %{
    "act" => {"browser.act.read", "browser.act"},
    "cookies" => {"browser.cookies", "browser.cookies.clear"},
    "storage" => {"browser.storage", "browser.storage.write"},
    "webmcp" => {"browser.webmcp", "browser.webmcp.call"}
  }
  # Each op in the owner's words (`op_label/1`).
  @op_labels %{
    "browser.doctor" => "check the browser",
    "browser.status" => "read the browser's state",
    "browser.start" => "start the browser",
    "browser.stop" => "stop the browser",
    "browser.open" => "open a page",
    "browser.navigate" => "go to a page",
    "browser.snapshot" => "read a page",
    "browser.tabs" => "list the tabs",
    "browser.focus" => "switch to a tab",
    "browser.close" => "close a tab",
    "browser.screenshot" => "take a screenshot",
    "browser.pdf" => "save a page as a PDF",
    "browser.console" => "read a page's console",
    "browser.dialog" => "answer a page's dialog",
    "browser.cookies" => "read cookies",
    "browser.cookies.clear" => "clear cookies",
    "browser.storage" => "read a site's stored data",
    "browser.storage.write" => "change a site's stored data",
    "browser.upload" => "upload a file",
    "browser.download" => "download a file",
    "browser.act" => "click or type on a page",
    "browser.act.read" => "read part of a page",
    "browser.webmcp" => "list a page's tools",
    "browser.webmcp.call" => "use a page's tool",
    "browser.handover" => "hand a page to you",
    "browser.login_for" => "look up a saved sign-in",
    "browser.sign_in" => "sign in to a site",
    "browser.end" => "end a browser task"
  }
  @artifacts %{"screenshot" => "screenshots", "pdf" => "pdf", "download" => "downloads"}
  @inline_bytes 256 * 1_024
  @result_bytes @inline_bytes + 16 * 1_024
  @max_part_bytes 20 * 1_024 * 1_024
  @end_deadline_ms 10_000
  # Beyond an op's own budget: a browser to start (Chrome's launch, or the
  # Fermix app opened for its pane) and the request's bytes on the link.
  @transfer_slack_ms 15_000
  @conversation ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @upload_name_bytes 255
  @staged_ms 24 * 60 * 60_000
  @owner "owner"

  @typedoc """
  This computer's browser, as an invocation's context carries it: its
  configuration, where its folders are, the held turns' registry and
  supervisor, and the seams of `Routing`, `ProfileManager` and `TurnMarker`
  (`FermixCore.Browser.serve/6`).
  """
  @type seams :: %{
          required(:config) => Config.t(),
          required(:browser_dir) => Path.t(),
          required(:uploads) => Path.t(),
          required(:turns) => HeldTurn.seams(),
          optional(:routing) => keyword(),
          optional(:manager) => keyword(),
          optional(:turn_marker) => atom()
        }

  @impl true
  def id, do: :browser

  @impl true
  def offer, do: :browser

  @impl true
  def ops, do: @ops |> Map.keys() |> Enum.sort()

  @impl true
  def label, do: BrowserOffer.label()

  @impl true
  def op_label(op) when is_map_key(@ops, op), do: Map.fetch!(@op_labels, op)

  @impl true
  def effect?(op) when is_map_key(@ops, op), do: elem(Map.fetch!(@ops, op), 1)

  @impl true
  def long_lived?(op) when is_map_key(@ops, op), do: false

  # The server has a browser of its own: a call that names no computer runs
  # there, unless its turn's browser already runs on one (`continues_on/1`).
  @impl true
  def here?(context) when is_map(context), do: true

  @impl true
  def continues_on(context) when is_map(context),
    do: ComputerTurn.continues_on(turn_seams(context), self())

  @doc "The held turns of the server's own side, from the loop context (tests name theirs)."
  @spec turn_seams(map()) :: ComputerTurn.seams()
  def turn_seams(context) when is_map(context),
    do: Map.get_lazy(context, :browser_turns, &HeldTurn.seams/0)

  @doc """
  The op that carries a request for `action` with `args`: by action, and for
  an action that reads in one form and changes something in another, by
  which form `FermixCore.Browser.mutating?/2` says it is.
  """
  @spec op(String.t(), map()) :: String.t()
  def op(action, args) when is_map_key(@split, action) and is_map(args) do
    {read, write} = Map.fetch!(@split, action)
    if Browser.mutating?(action, args), do: write, else: read
  end

  def op(action, args) when is_binary(action) and is_map(args), do: "browser." <> action

  @impl true
  def validate("browser.end", %{"turn" => ending}) when ending in ["ended", "stopped"], do: :ok
  def validate("browser.end", _args), do: {:error, "Say whether the turn ended or stopped."}

  def validate(op, %{"action" => action, "args" => args} = request)
      when is_binary(action) and is_map(args) do
    cond do
      not is_map_key(@ops, op) or op(action, args) != op ->
        {:error, "This request is not the one its operation names."}

      not conversation?(request["conversation"]) ->
        {:error, "The request names no conversation."}

      not (is_nil(request["profile"]) or is_binary(request["profile"])) ->
        {:error, "A browser profile is named by a string."}

      true ->
        upload_named(op, args)
    end
  end

  def validate(_op, _args), do: {:error, "A browser request names its action and arguments."}

  @impl true
  def bounds(op) when is_map_key(@ops, op),
    do: %{result_bytes: @result_bytes, part_bytes: @max_part_bytes}

  @impl true
  def deadline_ms("browser.end", _args), do: @end_deadline_ms

  def deadline_ms(op, args) when is_map_key(@ops, op) and is_map(args),
    do: budget(op, Map.get(args, "args", %{})) + start_slack()

  @impl true
  def target("browser.end", _args), do: "the end of a turn"

  def target(_op, %{"action" => action, "args" => args} = request) when is_map(args) do
    [profile_word(request["profile"]), action_words(action, args)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def target(op, _args), do: op

  # -- on this computer -----------------------------------------------------------

  @impl true
  def admit("browser.end", _args, _context), do: :ok

  def admit(op, request, %{origin: origin} = context) do
    with {:ok, seams} <- seams(context),
         :ok <- on_a_turn(origin),
         :ok <- signs_in_on(op, origin),
         :ok <- hands_over_on(op, origin) do
      granted_tab(seams.config, request["profile"], origin)
    end
  end

  @impl true
  def run("browser.end", %{"turn" => ending}, nil, context) do
    with {:ok, seams} <- seams(context),
         {:ok, session} <- session(context) do
      :ok = HeldTurn.finish(seams.turns, session, ending)
      {:ok, %{"ended" => ending}, nil}
    end
  end

  def run(op, request, part, context) do
    with {:ok, seams} <- seams(context),
         {:ok, session} <- session(context),
         {:ok, args} <- staged(op, request, part, seams, context.id) do
      turn = %{
        session: session,
        conversation: request["conversation"],
        worker?: context.origin == :worker
      }

      {served, backend} =
        HeldTurn.run(seams.turns, turn, fn -> serve(op, request, args, seams) end)

      answered(served, backend, request["action"], seams)
    end
  end

  @doc """
  This computer's browser on a running engine: its configuration now, its own
  folders, and the production registries. What `Desktop.Invoke` hands each
  invocation (`:browser`), read at each request.
  """
  @spec local() :: {:ok, seams()} | {:error, Error.t()}
  def local do
    with {:ok, config} <- Config.current() do
      paths = ConfigStore.workspace_paths()

      {:ok,
       %{
         config: config,
         browser_dir: paths.browser,
         uploads: uploads_dir(paths.workspace),
         turns: HeldTurn.seams(),
         turn_marker: TurnMarker
       }}
    end
  end

  @doc """
  The folder an upload from the server waits in, inside `workspace`: a page's
  file input takes a file of the workspace and nothing else
  (`Browser.Upload`).
  """
  @spec uploads_dir(Path.t()) :: Path.t()
  def uploads_dir(workspace) when is_binary(workspace),
    do: Path.join(workspace, "browser-uploads")

  defp serve(op, request, args, seams) do
    affinity = {"server", request["conversation"], :root}
    keys = %{owner: @owner, pane: Scope.pane_key(@owner, affinity)}

    case Config.profile(seams.config, request["profile"]) do
      {:ok, profile, name} ->
        context = %{agent_name: "computer", conversation_key: affinity, tab_affinity: affinity}
        served = %{action: request["action"], args: args, context: context, mutating: effect?(op)}
        Browser.serve(served, keys, name, profile, seams.config, Map.take(seams, serve_seams()))

      {:error, %Error{} = error} ->
        {{:error, error}, nil}
    end
  end

  defp serve_seams, do: [:routing, :manager, :turn_marker]

  # -- the answer -------------------------------------------------------------------

  defp answered({:ok, result}, backend, action, seams)
       when is_map_key(@artifacts, action) and is_binary(:erlang.map_get("path", result)),
       do: with_artifact(result, backend, action, seams)

  defp answered({:ok, result}, backend, _action, _seams) do
    json = Jason.encode!(result)

    if byte_size(json) <= @inline_bytes,
      do: {:ok, %{"result" => result, "backend" => label(backend)}, nil},
      else: {:ok, %{"result_part" => true, "backend" => label(backend)}, json}
  end

  defp answered({:error, %Error{} = error}, backend, _action, _seams) do
    said = Error.to_map(error)
    said = if inline?(said), do: said, else: Map.put(said, "details", %{})
    {:failed, first_line(error.message), %{"error" => said, "backend" => label(backend)}, nil}
  end

  # The browser wrote the file into this computer's browser folder; its bytes
  # are the answer, and the server keeps them, so this copy goes.
  defp with_artifact(%{"path" => path} = result, backend, action, seams) do
    with {:ok, bytes} <- artifact_bytes(path, seams.browser_dir) do
      _removed = File.rm(path)
      artifact = %{"kind" => Map.fetch!(@artifacts, action), "name" => Path.basename(path)}

      {:ok,
       %{
         "result" => Map.delete(result, "path"),
         "artifact" => artifact,
         "backend" => label(backend)
       }, bytes}
    end
  end

  defp artifact_bytes(path, browser_dir) do
    canonical = PathPolicy.canonical_path(path)
    root = PathPolicy.canonical_path(browser_dir)

    if String.starts_with?(canonical, root <> "/"),
      do: sized(canonical, File.stat(canonical)),
      else: {:failed, "The browser wrote its file outside this computer's browser folder."}
  end

  defp sized(path, {:ok, %{type: :regular, size: size}}) when size <= @max_part_bytes do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:failed, "The browser's file could not be read: #{format(reason)}."}
    end
  end

  defp sized(_path, {:ok, %{type: :regular, size: size}}),
    do:
      {:failed,
       "The file is #{size} bytes; a computer sends at most 20 MiB at once, so it stays on " <>
         "this computer."}

  defp sized(_path, _not_a_file), do: {:failed, "The browser's file is not there to send."}

  defp format(reason), do: :file.format_error(reason)

  # -- an upload ----------------------------------------------------------------------

  # The server sent the file's bytes; they wait in this computer's upload
  # folder, where its browser takes them, for as long as a page may read them.
  defp staged("browser.upload", %{"args" => args}, part, seams, id) when is_binary(part) do
    dir = Path.join(seams.uploads, id)
    path = Path.join(dir, args["upload_name"])
    :ok = prune_staged(seams.uploads)

    with :ok <- File.mkdir_p(dir), :ok <- File.write(path, part) do
      {:ok, args |> Map.delete("upload_name") |> Map.put("path", path)}
    else
      {:error, reason} -> {:failed, "The file could not be kept here: #{format(reason)}."}
    end
  end

  defp staged("browser.upload", _request, nil, _seams, _id),
    do: {:failed, "The file to upload did not come with the request."}

  defp staged(_op, %{"args" => args}, nil, _seams, _id), do: {:ok, args}
  defp staged(_op, _request, _part, _seams, _id), do: {:failed, "This takes no file."}

  # Files a page was given more than a day ago are gone; bounded by what the
  # folder holds.
  defp prune_staged(uploads) do
    cutoff = System.os_time(:millisecond) - @staged_ms

    case File.ls(uploads) do
      {:ok, entries} -> Enum.each(entries, &prune_entry(Path.join(uploads, &1), cutoff))
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("browser uploads not pruned: #{inspect(reason)}")
    end

    :ok
  end

  defp prune_entry(dir, cutoff) do
    case File.stat(dir, time: :posix) do
      {:ok, %{mtime: mtime}} when mtime * 1_000 < cutoff -> remove_staged(dir)
      _recent_or_gone -> :ok
    end
  end

  defp remove_staged(dir) do
    case File.rm_rf(dir) do
      {:ok, _removed} ->
        :ok

      {:error, reason, _path} ->
        Logger.warning("a browser upload was not removed: #{inspect(reason)}")
    end
  end

  defp upload_named("browser.upload", args) do
    name = args["upload_name"]

    if is_binary(name) and byte_size(name) in 1..@upload_name_bytes and name not in [".", ".."] and
         not String.contains?(name, ["/", "\\", <<0>>]) and not Map.has_key?(args, "path"),
       do: :ok,
       else: {:error, "An upload names its file, and only by its name."}
  end

  defp upload_named(_op, _args), do: :ok

  # -- the rules here --------------------------------------------------------------------

  defp seams(%{browser: {:ok, %{config: %Config{}} = seams}}), do: {:ok, seams}

  defp seams(%{browser: {:error, %Error{message: message}}}),
    do: {:refused, :unavailable, "This computer's browser cannot be used: #{message}"}

  defp seams(_context),
    do: {:refused, :unavailable, "This computer runs no browser for its server."}

  defp session(%{turn: %{session_id: session}}) do
    if HeldTurn.session?(session),
      do: {:ok, session},
      else: {:refused, :unavailable, "This request names no turn this computer can hold."}
  end

  defp session(_context),
    do: {:refused, :unavailable, "This request names no turn this computer can hold."}

  defp on_a_turn(origin) do
    if Origin.turn?(origin),
      do: :ok,
      else: {:refused, :unavailable, "Only a turn on the server uses this computer's browser."}
  end

  defp signs_in_on(op, :chat) when op in ["browser.login_for", "browser.sign_in"], do: :ok

  defp signs_in_on(op, :voice) when op in ["browser.login_for", "browser.sign_in"],
    do: {:refused, :unavailable, "A sign-in is approved in the chat, not by voice."}

  defp signs_in_on(op, _origin) when op in ["browser.login_for", "browser.sign_in"],
    do: {:refused, :not_attended, "A sign-in runs only on the owner's own turn in the chat."}

  defp signs_in_on(_op, _origin), do: :ok

  defp hands_over_on("browser.handover", origin) do
    if Origin.attended?(origin),
      do: :ok,
      else: {:refused, :not_attended, "A tab is handed over only on a turn the owner is in."}
  end

  defp hands_over_on(_op, _origin), do: :ok

  defp granted_tab(config, profile, origin) do
    case Config.profile(config, profile) do
      {:ok, %{mode: :attached_tab}, _name} ->
        if Origin.attended?(origin),
          do: :ok,
          else:
            {:refused, :not_attended,
             "The owner's own browser tab on this computer is used only on a turn they are in."}

      _not_a_granted_tab ->
        :ok
    end
  end

  # -- the words --------------------------------------------------------------------------

  defp budget("browser.download", args),
    do: bounded(args["timeout_ms"], defaults().download_default_ms, defaults().download_max_ms)

  defp budget("browser.act.read", %{"kind" => "wait"} = args),
    do: bounded(args["timeout_ms"], defaults().wait_default_ms, defaults().wait_max_ms)

  defp budget("browser.webmcp.call", _args), do: Config.webmcp_limits().call_max_ms

  defp budget(_op, _args),
    do: defaults().navigation_timeout_ms + Config.act_limits().navigation_budget_ms

  # A request may start the browser first: Chrome's launch, or the Fermix app
  # opened for its pane, then the bytes on the link.
  defp start_slack,
    do: defaults().launch_timeout_ms + defaults().host_launch_timeout_ms + @transfer_slack_ms

  # The browser's timeouts are internal constants, the same on every engine.
  defp defaults, do: %Config{}

  defp bounded(value, _default, max) when is_integer(value) and value > 0, do: min(value, max)
  defp bounded(_value, default, _max), do: default

  defp profile_word(profile) when is_binary(profile) and profile != "", do: profile <> ":"
  defp profile_word(_profile), do: nil

  # A host or an action, never content: an address's host alone, an act's
  # kind, a sign-in's site.
  defp action_words(action, args) when action in ["open", "navigate"],
    do: "#{action} #{host(args["url"])}"

  defp action_words("act", %{"kind" => kind}) when is_binary(kind), do: "act #{word(kind)}"

  defp action_words(action, args) when action in ["login_for", "sign_in"],
    do: "sign in #{site(args)}"

  defp action_words("webmcp", %{"op" => op}) when op in ["list", "call"], do: "webmcp #{op}"
  defp action_words(action, _args) when is_binary(action), do: word(action)
  defp action_words(_action, _args), do: "browser"

  defp host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> word(host)
      _no_host -> "a page"
    end
  end

  defp host(_url), do: "a page"

  defp site(%{"site" => site}) when is_binary(site), do: word(site)
  defp site(_args), do: "a site"

  defp word(text), do: text |> String.replace(~r/[^A-Za-z0-9._:-]/, "") |> String.slice(0, 96)

  defp conversation?(value), do: is_binary(value) and Regex.match?(@conversation, value)

  defp label(nil), do: nil
  defp label(backend) when backend in [:cdp, :fermix_app], do: Atom.to_string(backend)

  defp inline?(map), do: byte_size(Jason.encode!(map)) <= @inline_bytes

  defp first_line(message) do
    message
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end
end
