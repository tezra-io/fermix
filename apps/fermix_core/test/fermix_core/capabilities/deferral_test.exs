defmodule FermixCore.Capabilities.DeferralTest do
  # async: false — exercises the global [fermix_core :tools] config.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Deferral

  defmodule FakeMod do
    def execute(_args, _ctx), do: {:ok, :ok}
  end

  setup do
    previous = Application.get_env(:fermix_core, :tools)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :tools)
        value -> Application.put_env(:fermix_core, :tools, value)
      end
    end)

    :ok
  end

  defp enable_deferral,
    do: Application.put_env(:fermix_core, :tools, tool_search: [enabled: true])

  defp cap(name, opts \\ []) do
    Capability.new(%{
      name: name,
      description: "test #{name}",
      parameters: %{type: "object"},
      kind: Keyword.get(opts, :kind, :builtin),
      executor: {FakeMod, :execute, []},
      policy_class: Keyword.get(opts, :policy_class, :read_only),
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  describe "enabled?/0" do
    test "defaults to TRUE when unset (default-on; upgraded installs get deferral)" do
      Application.put_env(:fermix_core, :tools, [])
      assert Deferral.enabled?()

      Application.delete_env(:fermix_core, :tools)
      assert Deferral.enabled?()
    end

    test "reads the boolean" do
      enable_deferral()
      assert Deferral.enabled?()

      Application.put_env(:fermix_core, :tools, tool_search: [enabled: false])
      refute Deferral.enabled?()
    end

    test "non-boolean values fail loud (no silent fallback)" do
      Application.put_env(:fermix_core, :tools, tool_search: [enabled: "auto"])

      assert_raise ArgumentError, ~r/enabled must be true or false/, fn ->
        Deferral.enabled?()
      end
    end
  end

  describe "deferred?/1" do
    test "plugin-category and mcp-kind capabilities defer" do
      assert Deferral.deferred?(
               cap("x_whoami", metadata: %{plugin_owned?: true, category: :plugin})
             )

      assert Deferral.deferred?(cap("mcp_srv_tool", kind: :mcp))
    end

    test "builtins and the bridges never defer" do
      refute Deferral.deferred?(cap("shell", policy_class: :exec))
      refute Deferral.deferred?(cap("web_search", policy_class: :network))
      # Bridge names are reserved even if mislabeled with plugin metadata.
      refute Deferral.deferred?(cap("tool_search", metadata: %{category: :plugin}))
      refute Deferral.deferred?(cap("tool_describe", metadata: %{category: :plugin}))
      refute Deferral.deferred?(cap("tool_call", metadata: %{category: :plugin}))
    end
  end

  describe "partition/1" do
    test "disabled: everything advertised, nothing deferred (explicit kill switch)" do
      Application.put_env(:fermix_core, :tools, tool_search: [enabled: false])
      caps = [cap("shell"), cap("x_whoami", metadata: %{category: :plugin})]

      assert %{advertised: ^caps, deferred: []} = Deferral.partition(caps)
    end

    test "enabled: plugin/mcp split out, relative order preserved" do
      enable_deferral()

      shell = cap("shell")
      x = cap("x_whoami", metadata: %{category: :plugin})
      mcp = cap("mcp_srv_tool", kind: :mcp)
      help = cap("tool_help")

      assert %{advertised: [^shell, ^help], deferred: [^x, ^mcp]} =
               Deferral.partition([shell, x, mcp, help])
    end
  end
end
