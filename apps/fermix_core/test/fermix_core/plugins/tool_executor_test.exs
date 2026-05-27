defmodule FermixCore.Plugins.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.ToolExecutor

  test "searches Google Drive files with a resolved token" do
    parent = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {:drive_request, conn.request_path, conn.query_params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "files" => [
            %{
              "id" => "file-1",
              "name" => "Q2 Plan",
              "mimeType" => "application/vnd.google-apps.document"
            }
          ]
        })
      )
    end

    context = %{
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_drive:primary" -> {:ok, "drive-token"} end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"query" => "Q2 Plan", "max_results" => 3},
               context,
               "google_drive",
               %{"name" => "google_drive.search_files", "read_only" => true}
             )

    assert result.success == true

    assert Jason.decode!(result.output)["files"] |> List.first() |> Map.fetch!("name") ==
             "Q2 Plan"

    assert_received {:drive_request, "/drive/v3/files", params}
    assert params["pageSize"] == "3"
    assert params["q"] == "trashed = false and name contains 'Q2 Plan'"
  end

  test "refreshes once and retries read-only plugin requests on 401" do
    parent = self()

    plug = fn conn ->
      auth = Plug.Conn.get_req_header(conn, "authorization") |> List.first()
      send(parent, {:provider_request, auth})

      case auth do
        "Bearer old-token" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(401, Jason.encode!(%{"error" => "expired"}))

        "Bearer fresh-token" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end
    end

    context = %{
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_calendar:primary" -> {:ok, "old-token"} end,
      plugin_token_refresher: fn "google_calendar:primary" -> {:ok, "fresh-token"} end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"query" => "standup"},
               context,
               "google_calendar",
               %{"name" => "google_calendar.search_events", "read_only" => true}
             )

    assert result.success == true
    assert Jason.decode!(result.output) == %{"items" => []}
    assert_received {:provider_request, "Bearer old-token"}
    assert_received {:provider_request, "Bearer fresh-token"}
  end

  test "returns scope guidance and redacts provider bodies on 403" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        403,
        Jason.encode!(%{"error" => %{"message" => "token secret-access-token lacks scope"}})
      )
    end

    context = %{
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_calendar:primary" -> {:ok, "secret-access-token"} end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{
                 "summary" => "Demo",
                 "start" => "2026-05-24T10:00:00Z",
                 "end" => "2026-05-24T11:00:00Z"
               },
               context,
               "google_calendar",
               %{
                 "name" => "google_calendar.create_event",
                 "read_only" => false,
                 "requires_scopes" => ["https://www.googleapis.com/auth/calendar.events"]
               }
             )

    assert result.success == false
    assert result.error =~ "missing a required scope"
    assert result.error =~ "https://www.googleapis.com/auth/calendar.events"
    assert result.error =~ "fermix plugins auth reauthorize google_calendar"
    refute result.error =~ "secret-access-token"
  end

  test "maps enabled but unconnected plugins to no auth guidance" do
    context = %{
      plugin_token_getter: fn "google_calendar:primary" ->
        {:error, {:provider_missing, "google_calendar:primary"}}
      end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"query" => "standup"},
               context,
               "google_calendar",
               %{"name" => "google_calendar.search_events", "read_only" => true}
             )

    assert result.success == false
    assert result.error =~ "enabled but not connected"
    assert result.error =~ "fermix plugins auth login google_calendar"
  end
end
