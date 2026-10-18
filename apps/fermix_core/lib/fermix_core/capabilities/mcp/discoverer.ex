defmodule FermixCore.Capabilities.MCP.Discoverer do
  @moduledoc """
  Behaviour for "discover the tools an MCP server exposes."

  Production uses `FermixCore.Capabilities.MCP.Discoverer.Anubis`, which
  delegates to `Anubis.Client.list_tools/2`. Tests stub this
  behaviour to avoid spawning real `npx` subprocesses.

  What a discovery found is also kept for the owner to read (M74 E9): the
  server's own `serverInfo` from `initialize` and, for each tool in the order
  the server listed them, its title, description and the two annotations that
  say what it does. `discovery/2` is the one projection of that, bounded, and
  `RuntimeStatus` keeps it beside the source's status. It informs; no policy
  reads it.
  """

  @type tool_descriptor :: %{
          required(:name) => String.t(),
          optional(:title) => String.t() | nil,
          optional(:description) => String.t(),
          optional(:input_schema) => map(),
          optional(:output_schema) => map() | nil,
          optional(:annotations) => map() | nil
        }

  @typedoc "One listed tool, as the owner reads it."
  @type tool_metadata :: %{
          name: String.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          read_only: boolean(),
          destructive: boolean()
        }

  @typedoc "The server's own `serverInfo`, as `initialize` answered it."
  @type server_info :: %{
          name: String.t() | nil,
          title: String.t() | nil,
          version: String.t() | nil
        }

  @typedoc "What one discovery found: every tool counted, the first 256 described."
  @type discovery :: %{
          tool_count: non_neg_integer(),
          server_info: server_info() | nil,
          tools: [tool_metadata()]
        }

  # The row publishes at most this many tools, in the server's order (M74 §5),
  # and each text inside a bound, so one server's list stays far inside the
  # protocol's result bound however much its descriptions say.
  @max_described_tools 256
  @max_title_chars 128
  @max_description_chars 512
  @max_info_chars 128

  @callback list_tools(client :: term()) ::
              {:ok, [tool_descriptor()]} | {:error, term()}

  @doc """
  The `serverInfo` the server answered `initialize` with, or `nil` when it has
  not answered one.
  """
  @callback server_info(client :: term()) :: map() | nil

  @doc """
  Ask this discoverer to report upstream tool-list changes to `listener`.

  REQUIRED for any discoverer serving a signed contract: a contract-bearing
  source has a registration that a `notifications/tools/list_changed`
  invalidates, and the registration owner is the only process that can rebuild
  it (M27 §7.6). Without this the notification has nowhere to go and the whole
  suspension/rediscovery path is unreachable from the wire.

  Optional because a stdio source carries no contract, so there is no signed
  registration to invalidate — `Discoverer.Anubis` need not implement it.

  Idempotent: the registration owner re-arms the watch on every discovery pass,
  and the last listener wins.
  """
  @callback watch_tools(client :: term(), listener :: pid()) :: :ok | {:error, term()}

  @optional_callbacks watch_tools: 2

  @doc """
  The ONE definition of a normalized tool descriptor, shared by every discovery
  path (stdio via `Discoverer.Anubis`, remote via `Remote.Owner`).

  It lives here, beside the type it produces, because the signed descriptor
  (M27 §7.6) is the canonicalization of **name + inputSchema + outputSchema +
  annotations** — so a path that drops any of those hashes to something the
  publisher never signed, and every tool reads as drifted. That has now
  happened twice, once per path, because each had its own copy of this
  function. There is one copy.

  Absent `outputSchema`/`annotations` normalize to `nil`, which
  `CanonicalJson.descriptor_digest/4` hashes identically to an explicit null —
  a server that simply omits a field must not read as drift. Keys stay in their
  wire (string-keyed JSON) form, which is what the signature is defined over.
  """
  @spec normalize(map()) :: tool_descriptor()
  def normalize(tool) when is_map(tool) do
    %{
      name: Map.get(tool, "name") || Map.get(tool, :name),
      title: Map.get(tool, "title") || Map.get(tool, :title),
      description: Map.get(tool, "description") || Map.get(tool, :description) || "",
      input_schema:
        Map.get(tool, "inputSchema") || Map.get(tool, :input_schema) ||
          %{"type" => "object", "properties" => %{}},
      output_schema: Map.get(tool, "outputSchema") || Map.get(tool, :output_schema),
      annotations: Map.get(tool, "annotations") || Map.get(tool, :annotations)
    }
  end

  @doc """
  What a discovery found, for the owner (M74 E9): how many tools the server
  listed, its `serverInfo`, and the first #{@max_described_tools} tools in its
  order, each with its title, description and the server's own
  `readOnlyHint` and `destructiveHint`.

  A hint is what the server declared: an absent one is `false`, and a tool
  that says it only reads is never also destructive. The title is the tool's
  `title`, else its `annotations.title`, the order the MCP specification gives
  for a display name; blank text counts as none.
  """
  @spec discovery([tool_descriptor()], map() | nil) :: discovery()
  def discovery(descriptors, server_info)
      when is_list(descriptors) and (is_map(server_info) or is_nil(server_info)) do
    %{
      tool_count: length(descriptors),
      server_info: server_info(server_info),
      tools: descriptors |> Enum.take(@max_described_tools) |> Enum.map(&tool_metadata/1)
    }
  end

  defp server_info(nil), do: nil

  defp server_info(info) do
    %{
      name: bounded(Map.get(info, "name"), @max_info_chars),
      title: bounded(Map.get(info, "title"), @max_info_chars),
      version: bounded(Map.get(info, "version"), @max_info_chars)
    }
  end

  defp tool_metadata(descriptor) do
    annotations = annotations(descriptor)
    read_only = Map.get(annotations, "readOnlyHint") == true

    %{
      name: descriptor.name,
      title: title(descriptor, annotations),
      description: bounded(Map.get(descriptor, :description), @max_description_chars),
      read_only: read_only,
      destructive: not read_only and Map.get(annotations, "destructiveHint") == true
    }
  end

  defp title(descriptor, annotations) do
    bounded(Map.get(descriptor, :title), @max_title_chars) ||
      bounded(Map.get(annotations, "title"), @max_title_chars)
  end

  defp annotations(%{annotations: annotations}) when is_map(annotations), do: annotations
  defp annotations(_descriptor), do: %{}

  # Bounded in characters, never bytes, so a cut never splits a character and
  # the row stays valid UTF-8. Blank text is no text.
  defp bounded(text, max) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max)
    end
  end

  defp bounded(_text, _max), do: nil
end

defmodule FermixCore.Capabilities.MCP.Discoverer.Anubis do
  @moduledoc """
  Production discoverer: calls `Anubis.Client.list_tools/2`.
  """

  @behaviour FermixCore.Capabilities.MCP.Discoverer

  alias FermixCore.Capabilities.MCP.Discoverer

  @impl true
  def list_tools(client) do
    client |> Anubis.Client.list_tools() |> interpret_response()
  end

  @impl true
  def server_info(client), do: Anubis.Client.get_server_info(client)

  @doc """
  Decode the `Anubis.Client.list_tools/2` return into the
  `Discoverer` callback shape. Public so tests can exercise each
  response shape without spawning a real MCP transport.
  """
  @spec interpret_response({:ok, term()} | {:error, term()}) ::
          {:ok, [FermixCore.Capabilities.MCP.Discoverer.tool_descriptor()]} | {:error, term()}
  def interpret_response({:ok, %Anubis.MCP.Response{is_error: true} = response}) do
    {:error, {:tools_error, response}}
  end

  def interpret_response({:ok, %Anubis.MCP.Response{result: %{"tools" => tools}}})
      when is_list(tools) do
    {:ok, Enum.map(tools, &normalize/1)}
  end

  def interpret_response({:ok, response}), do: {:error, {:unexpected_tools_response, response}}
  def interpret_response({:error, reason}), do: {:error, reason}

  defp normalize(tool), do: Discoverer.normalize(tool)
end
