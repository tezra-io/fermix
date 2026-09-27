defmodule FermixCore.Browser.Backend do
  @moduledoc """
  The browser surface a profile's backend implements: one callback per
  operation the `browser` tool asks of a browser, plus the runtime's lifetime.

  `ProfileServer` is the backend-neutral half. It is the one process per
  `{owner, profile}`, starts nothing until asked, stops itself when idle, runs
  one request at a time, and refuses what the profile's mode cannot do
  (`Capabilities`) before a backend is asked. A backend is everything that
  talks to a browser: bringing its runtime up and down, its tabs, what its
  pages answer, and the navigation and read gates (`Policy`) asked on the
  backend's own view of a page.

  `CDP.Backend` drives Chrome over the DevTools protocol, whoever launched it
  and whichever transport reaches it. `HostServer` is the Fermix app's own
  browser pane (`:fermix_app`), over the app's local wire.

  ## The contract

  A backend's state is its own; the server only threads it. Every operation
  brings the runtime up itself when it is not running, after whatever must
  refuse without a browser: a navigation's policy verdict refuses before
  anything is launched. An operation answers with the backend's state on every
  path, because a failed operation may still have changed it (a download
  marked reported, a document response taken out of the mailbox).

  Arguments arrive validated for shape by `FermixCore.Browser`; a backend
  keeps its own floor under a direct call.
  """

  alias FermixCore.Browser.CDP
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HostServer

  @typedoc "A backend's own state, threaded by `ProfileServer`."
  @type state :: term()

  @typedoc "One action's tool arguments, string-keyed as the model sent them."
  @type args :: %{optional(String.t()) => term()}

  @typedoc "The tool call's context (`:agent_name`, `:conversation_key`, …)."
  @type context :: map()

  @typedoc """
  An operation's answer, with the backend's state on every path. `:reap` is a
  refusal after which the profile must not take another request: the server
  answers it and stops, and the next request starts a fresh profile.
  """
  @type result ::
          {:ok, map(), state()} | {:error, Error.t(), state()} | {:reap, Error.t(), state()}

  @doc "The backend's state, from `ProfileServer`'s start options."
  @callback init(opts :: keyword()) :: state()

  @doc "The runtime's own status fields: `running`, `tabs`, and what else it reports."
  @callback status(state()) :: map()

  @doc "Bring the runtime up when it is not running."
  @callback start(context(), state()) ::
              {:ok, state()} | {:error, Error.t(), state()} | {:reap, Error.t(), state()}

  @doc "Tear the runtime down. Idempotent, and called on every exit path."
  @callback stop(state()) :: state()

  @doc "A message the runtime sent the server process: an event, port output, an exit."
  @callback handle_message(message :: term(), state()) :: state()

  @doc "The page console entries a failed operation carries, newest first."
  @callback console_buffer(state()) :: [map()]

  @doc "Open a new tab on `url`; unless `observe` is false, hand the loaded page back."
  @callback open(args(), context(), state()) :: result()

  @doc "Navigate a tab (`target`, or the active one) to `url`; hands the page back as `open` does."
  @callback navigate(args(), context(), state()) :: result()

  @doc "Render a tab's page for the model and remember its element refs."
  @callback snapshot(args(), context(), state()) :: result()

  @doc "List the tabs."
  @callback tabs(args(), context(), state()) :: result()

  @doc "Bring a tab to the front."
  @callback focus(args(), context(), state()) :: result()

  @doc "Close a tab."
  @callback close(args(), context(), state()) :: result()

  @doc "Capture a tab as an image artifact in the workspace."
  @callback screenshot(args(), context(), state()) :: result()

  @doc "Print a tab to a PDF artifact in the workspace."
  @callback pdf(args(), context(), state()) :: result()

  @doc "A tab's recent console entries and page exceptions."
  @callback console(args(), context(), state()) :: result()

  @doc "Answer the open JavaScript dialog (`decision`), or list the open ones."
  @callback dialog(args(), context(), state()) :: result()

  @doc ~s(List cookie metadata, never values, or clear every cookie with `kind: "clear"`.)
  @callback cookies(args(), context(), state()) :: result()

  @doc "Read or write a page's local or session storage."
  @callback storage(args(), context(), state()) :: result()

  @doc "Put a workspace file (`path`) into a file input (`ref`)."
  @callback upload(args(), context(), state()) :: result()

  @doc "Wait for the next finished download, within `timeout_ms`."
  @callback download(args(), context(), state()) :: result()

  @doc """
  One page interaction, by `kind`: `click`, `fill`, `fill_form`, `type`,
  `submit`, `press`, `hover`, `get`, `wait` or `click_coords`.
  """
  @callback act(args(), context(), state()) :: result()

  @doc ~s(List the tools the page offers over WebMCP \(`op: "list"`\), or call one \(`op: "call"`\).)
  @callback webmcp(args(), context(), state()) :: result()

  @doc "The backend that implements a profile mode."
  @spec for_mode(atom()) :: module()
  def for_mode(:fermix_app), do: HostServer
  def for_mode(mode) when is_atom(mode), do: CDP.Backend
end
