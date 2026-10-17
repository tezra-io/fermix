defmodule FermixCore.Capabilities.MCP.AnubisStdioTest do
  # The one test that drives the real Anubis client against a real stdio MCP
  # process. Every other MCP test stubs the discoverer, the caller or the
  # starter, so an Anubis upgrade that broke the handshake, discovery or a call
  # result would pass them all (M73 §7.1).
  #
  # `async: false`: the servers register in the application's MCP registry and
  # tool-name table, which `Caller.Anubis` and `MCP.Naming` read globally.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.MCP.AnubisStarter
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Server, as: McpServer
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  @fixture Path.expand("../../../fixtures/mcp_stdio_server.exs", __DIR__)

  # A fresh `elixir` process booting and answering `initialize`, on the slowest
  # CI leg under load. A passing run returns the moment the handshake lands.
  @handshake_bound_ms 20_000

  setup do
    elixir = System.find_executable("elixir") || raise "no `elixir` executable on PATH"
    suffix = System.unique_integer([:positive])

    cap_registry =
      start_supervised!(
        {CapabilityRegistry, name: :"mcp_stdio_cap_reg_#{suffix}"},
        id: :"mcp_stdio_cap_reg_child_#{suffix}"
      )

    %{elixir: elixir, suffix: suffix, cap_registry: cap_registry}
  end

  test "the handshake completes and discovery registers the server's tools", ctx do
    name = start_stdio_server(ctx, "wire#{ctx.suffix}")

    assert registered_names(ctx) == ["mcp_#{name}_echo", "mcp_#{name}_refuse"]
  end

  test "a call returns the child's text, and an isError reply is a tool error in its words",
       ctx do
    name = start_stdio_server(ctx, "wire#{ctx.suffix}")

    assert {:ok, echoed} =
             Capability.execute(capability(ctx, name, "echo"), %{"text" => "hi"}, %{})

    assert echoed.success
    assert echoed.output == "echo: hi"

    assert {:ok, refused} = Capability.execute(capability(ctx, name, "refuse"), %{}, %{})
    refute refused.success
    assert refused.error =~ "MCP tool '#{name}/refuse' reported an error"
    assert refused.error =~ "the fixture refused"
  end

  # Anubis keys its per-client tool cache by the advertised client name, so two
  # stdio servers sharing one name crash on the second `tools/list` reply.
  test "two servers side by side keep their own client identity and both discover", ctx do
    first = start_stdio_server(ctx, "wirea#{ctx.suffix}")
    second = start_stdio_server(ctx, "wireb#{ctx.suffix}")

    assert registered_names(ctx) ==
             Enum.sort([
               "mcp_#{first}_echo",
               "mcp_#{first}_refuse",
               "mcp_#{second}_echo",
               "mcp_#{second}_refuse"
             ])
  end

  # Anubis 2.0 stores a version it no longer lists and keeps talking, as 1.6
  # did; 2.1 refuses the handshake. This case fails on that bump on purpose,
  # so the refusal is handled (M73 §9) instead of slipping through.
  test "a server that answers protocol 2024-11-05 still connects", ctx do
    name = start_stdio_server(ctx, "wireold#{ctx.suffix}", "2024-11-05")

    assert registered_names(ctx) == ["mcp_#{name}_echo", "mcp_#{name}_refuse"]
  end

  # The production client spec, then the discovery server once the handshake has
  # landed: `fail_fast?` discovers in `init/1`, so a start that returns has
  # registered the tools or failed loudly. Stdio registration claims the tool
  # names in the global `MCP.Naming` table and stopping the server does not
  # release them, so the test does.
  defp start_stdio_server(ctx, name, protocol_version \\ "2025-11-25") do
    on_exit(fn -> Enum.each(~w(echo refuse), &Naming.unregister("mcp_#{name}_#{&1}")) end)
    server = %{name: name, command: ctx.elixir, args: [@fixture, protocol_version]}

    %{children: [client_spec], client_name: client} =
      AnubisStarter.Default.child_specs_for(server, %{})

    start_supervised!(client_spec)
    assert :ok = Anubis.Client.await_ready(client, timeout: @handshake_bound_ms)

    start_supervised!(
      {McpServer,
       [
         server_name: name,
         client: client,
         capability_registry: ctx.cap_registry,
         fail_fast?: true
       ]},
      id: {:mcp_stdio_server, name}
    )

    name
  end

  defp registered_names(ctx) do
    ctx.cap_registry
    |> CapabilityRegistry.list(kind: :mcp)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp capability(ctx, server_name, tool) do
    name = "mcp_#{server_name}_#{tool}"

    ctx.cap_registry
    |> CapabilityRegistry.list(kind: :mcp)
    |> Enum.find(&(&1.name == name)) || flunk("#{name} is not registered")
  end
end
