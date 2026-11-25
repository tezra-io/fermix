defmodule FermixCore.Providers.ModelListingVercelKeyTest do
  # Not async: the key comes from the provider configuration, which is global.
  use ExUnit.Case, async: false

  alias FermixCore.Providers.ModelListing

  setup do
    previous = Application.get_env(:fermix_core, :providers, [])
    on_exit(fn -> Application.put_env(:fermix_core, :providers, previous) end)
    %{previous: previous}
  end

  # The configuration is cleared here, not assumed: config/runtime.exs reads
  # AI_GATEWAY_API_KEY into it, so a shell that exports one has a key.
  test "with no key passed or configured, the public listing is read", %{previous: previous} do
    Application.put_env(:fermix_core, :providers, Keyword.delete(previous, :vercel))

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      Req.Test.json(conn, %{"object" => "list", "data" => []})
    end)

    assert {:ok, []} =
             ModelListing.live_models(:vercel, req_options: [plug: {Req.Test, __MODULE__}])
  end

  # The apps ask through `providers.models.list`, which passes no key: the
  # listing asks with the one the daemon runs Vercel AI Gateway with (M105 §11.9).
  test "the configured key asks for the team's availability", %{previous: previous} do
    Application.put_env(
      :fermix_core,
      :providers,
      [{:vercel, [api_key: "vck-configured"]}] ++ Keyword.delete(previous, :vercel)
    )

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.query_string == "include_availability=true"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer vck-configured"]
      Req.Test.json(conn, %{"object" => "list", "data" => []})
    end)

    assert {:ok, []} =
             ModelListing.live_models(:vercel, req_options: [plug: {Req.Test, __MODULE__}])
  end

  test "a key passed in is the one used", %{previous: previous} do
    Application.put_env(
      :fermix_core,
      :providers,
      [{:vercel, [api_key: "vck-configured"]}] ++ Keyword.delete(previous, :vercel)
    )

    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer vck-typed"]
      Req.Test.json(conn, %{"object" => "list", "data" => []})
    end)

    assert {:ok, []} =
             ModelListing.live_models(:vercel,
               api_key: "vck-typed",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end
end
