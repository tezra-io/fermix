defmodule FermixCore.Plugins.ToolExecutorTest do
  # async: false — the executor's call-time disabled check (Status.status/1)
  # reads the global `:fermix_core, :plugins` app env, which setup below
  # establishes explicitly per the hermetic-config rule.
  use ExUnit.Case, async: false

  alias FermixCore.Plugins.ToolExecutor

  @calendar_scopes [
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/calendar.events"
  ]

  setup do
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})

    # Baseline: every plugin exercised here is enabled; google client config
    # stays blank so Status.status/1 never reads the auth store.
    Application.put_env(:fermix_core, :plugins,
      enabled: ["gmail", "google_calendar", "google_drive"]
    )

    Application.put_env(:fermix_core, :oauth, %{})

    on_exit(fn ->
      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
    end)

    :ok
  end

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
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_drive:primary" -> {:ok, "drive-token"} end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"query" => "Q2 Plan", "max_results" => 3},
               context,
               "google_drive",
               %{"name" => "google_drive_search_files", "read_only" => true}
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
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_calendar:primary" -> {:ok, "old-token"} end,
      plugin_token_refresher: fn "google_calendar:primary" -> {:ok, "fresh-token"} end,
      plugin_granted_scopes_getter: fn _ -> @calendar_scopes end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"query" => "standup"},
               context,
               "google_calendar",
               cal_tool("google_calendar_search_events")
             )

    assert result.success == true
    assert Jason.decode!(result.output) == %{"items" => []}
    assert_received {:provider_request, "Bearer old-token"}
    assert_received {:provider_request, "Bearer fresh-token"}
  end

  test "missing granted scope returns reauthorize guidance without calling the provider" do
    parent = self()

    plug = fn conn ->
      send(parent, {:provider_called, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{}")
    end

    context = %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_calendar:primary" -> {:ok, "tok"} end,
      plugin_granted_scopes_getter: fn _plugin ->
        ["https://www.googleapis.com/auth/calendar.readonly"]
      end
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
                 "name" => "google_calendar_create_event",
                 "read_only" => false,
                 "requires_scopes" => ["https://www.googleapis.com/auth/calendar.events"]
               }
             )

    assert result.success == false
    assert result.error =~ "missing a required scope"
    assert result.error =~ "https://www.googleapis.com/auth/calendar.events"
    assert result.error =~ "fermix plugins auth reauthorize google_calendar"
    refute_received {:provider_called, _path}
  end

  test "disabled plugin tool refuses at call time with enable guidance" do
    # Stale-context window (§4.5 gap 2): the registry still knows the plugin,
    # but it is NOT in the enabled set — established explicitly here.
    Application.put_env(:fermix_core, :plugins, enabled: [])

    parent = self()

    plug = fn conn ->
      send(parent, {:provider_called, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    context = %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn _ -> {:ok, "tok"} end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"query" => "Q2 Plan"},
               context,
               "google_drive",
               %{"name" => "google_drive_search_files", "read_only" => true}
             )

    assert result.success == false

    assert result.error ==
             "google_drive is disabled — enable it on the setup page or run " <>
               "`fermix plugins enable google_drive`."

    refute_received {:provider_called, _path}
  end

  test "server-side insufficient-scope 403 maps to reauthorize guidance and hides the body" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => 403,
            "status" => "PERMISSION_DENIED",
            "message" => "secret-access-token rejected",
            "details" => [
              %{
                "@type" => "type.googleapis.com/google.rpc.ErrorInfo",
                "reason" => "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
                "domain" => "googleapis.com"
              }
            ]
          }
        })
      )
    end

    context = %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_calendar:primary" -> {:ok, "secret-access-token"} end,
      plugin_granted_scopes_getter: fn _ -> @calendar_scopes end
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
               cal_tool("google_calendar_create_event")
             )

    assert result.success == false
    assert result.error =~ "missing a required scope"
    refute result.error =~ "secret-access-token"
  end

  test "file-permission 403 explains the access problem instead of asking to reauthorize" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => 403,
            "errors" => [
              %{
                "domain" => "global",
                "reason" => "insufficientFilePermissions",
                "message" => "no access"
              }
            ]
          }
        })
      )
    end

    context = %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_calendar:primary" -> {:ok, "tok"} end,
      plugin_granted_scopes_getter: fn _ -> @calendar_scopes end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"query" => "x"},
               context,
               "google_calendar",
               cal_tool("google_calendar_search_events")
             )

    assert result.success == false
    assert result.error =~ "does not have access"
    refute result.error =~ "reauthorize"
  end

  test "rate-limit 403 asks to retry rather than reauthorize" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => 403,
            "errors" => [
              %{
                "domain" => "usageLimits",
                "reason" => "rateLimitExceeded",
                "message" => "slow down"
              }
            ]
          }
        })
      )
    end

    context = %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_calendar:primary" -> {:ok, "tok"} end,
      plugin_granted_scopes_getter: fn _ -> @calendar_scopes end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"query" => "x"},
               context,
               "google_calendar",
               cal_tool("google_calendar_search_events")
             )

    assert result.success == false
    assert result.error =~ "rate-limited"
    refute result.error =~ "reauthorize"
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
               %{"name" => "google_calendar_search_events", "read_only" => true}
             )

    assert result.success == false
    assert result.error =~ "enabled but not connected"
    assert result.error =~ "fermix plugins auth login google_calendar"
  end

  test "enriches Gmail search results with sender, subject, and snippet" do
    parent = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {:gmail_request, conn.request_path, conn.query_params})

      body =
        case conn.request_path do
          "/gmail/v1/users/me/messages" ->
            %{"messages" => [%{"id" => "m1", "threadId" => "t1"}]}

          "/gmail/v1/users/me/messages/m1" ->
            %{
              "id" => "m1",
              "threadId" => "t1",
              "snippet" => "Are we still on for the Q2 sync?",
              "payload" => %{
                "headers" => [
                  %{"name" => "From", "value" => "Dana <dana@acme.test>"},
                  %{"name" => "Subject", "value" => "Q2 sync"},
                  %{"name" => "Date", "value" => "Mon, 1 Jun 2026 09:00:00 +0000"}
                ]
              }
            }
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    context = %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "gmail:primary" -> {:ok, "gmail-token"} end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"query" => "from:acme", "max_results" => 5},
               context,
               "gmail",
               %{"name" => "gmail_search_messages", "read_only" => true}
             )

    assert result.success == true

    message = Jason.decode!(result.output)["messages"] |> List.first()
    assert message["id"] == "m1"
    assert message["threadId"] == "t1"
    assert message["from"] == "Dana <dana@acme.test>"
    assert message["subject"] == "Q2 sync"
    assert message["snippet"] =~ "Q2 sync"

    assert_received {:gmail_request, "/gmail/v1/users/me/messages", %{"q" => "from:acme"}}
    assert_received {:gmail_request, "/gmail/v1/users/me/messages/m1", get_params}
    assert get_params["format"] == "metadata"
  end

  test "fetches a single Gmail message body and headers by id" do
    parent = self()
    body_text = "Confirmed — Tuesday at 10am works.\n"

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {:gmail_request, conn.request_path, conn.query_params})

      payload = %{
        "id" => "m1",
        "threadId" => "t1",
        "snippet" => "Confirmed",
        "payload" => %{
          "mimeType" => "multipart/alternative",
          "headers" => [
            %{"name" => "From", "value" => "Dana <dana@acme.test>"},
            %{"name" => "Subject", "value" => "Re: Q2 sync"},
            %{"name" => "Message-Id", "value" => "<msg-1@mail.test>"},
            %{"name" => "References", "value" => "<msg-0@mail.test>"}
          ],
          "parts" => [
            %{
              "mimeType" => "text/plain",
              "body" => %{"data" => Base.url_encode64(body_text, padding: false)}
            }
          ]
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end

    context = %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "gmail:primary" -> {:ok, "gmail-token"} end
    }

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"id" => "m1"},
               context,
               "gmail",
               %{"name" => "gmail_get_message", "read_only" => true}
             )

    assert result.success == true

    message = Jason.decode!(result.output)
    assert message["id"] == "m1"
    assert message["from"] == "Dana <dana@acme.test>"
    assert message["subject"] == "Re: Q2 sync"
    assert message["body"] == body_text
    assert message["message_id"] == "<msg-1@mail.test>"
    assert message["references"] == "<msg-0@mail.test>"

    assert_received {:gmail_request, "/gmail/v1/users/me/messages/m1", %{"format" => "full"}}
  end

  defp gmail_write_plug(parent, response) do
    fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:gmail_write, conn.request_path, raw_body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  @gmail_scopes [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.send",
    "https://www.googleapis.com/auth/gmail.compose",
    "https://www.googleapis.com/auth/gmail.modify"
  ]

  defp gmail_context(plug) do
    %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "gmail:primary" -> {:ok, "tok"} end,
      plugin_granted_scopes_getter: fn _ -> @gmail_scopes end
    }
  end

  defp gmail_tool(name), do: plugin_tool("gmail", name)

  test "creates a Gmail draft from the composed message" do
    plug = gmail_write_plug(self(), %{"id" => "draft-1", "message" => %{"id" => "m9"}})

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"to" => "a@b.test", "subject" => "Hi", "body" => "Hello there"},
               gmail_context(plug),
               "gmail",
               %{"name" => "gmail_create_draft", "read_only" => false}
             )

    assert result.success == true
    assert Jason.decode!(result.output)["id"] == "draft-1"
    assert_received {:gmail_write, "/gmail/v1/users/me/drafts", body}
    raw = Jason.decode!(body)["message"]["raw"] |> Base.url_decode64!(padding: false)
    assert raw =~ "To: a@b.test"
    assert raw =~ "Subject: Hi"
    assert raw =~ "Hello there"
  end

  test "sends an existing Gmail draft by id" do
    plug = gmail_write_plug(self(), %{"id" => "m9", "labelIds" => ["SENT"]})

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"id" => "draft-1"},
               gmail_context(plug),
               "gmail",
               gmail_tool("gmail_send_draft")
             )

    assert result.success == true
    assert_received {:gmail_write, "/gmail/v1/users/me/drafts/send", body}
    assert Jason.decode!(body)["id"] == "draft-1"
  end

  test "replies within a thread, setting threadId and reply headers" do
    plug = gmail_write_plug(self(), %{"id" => "m10", "threadId" => "t1"})

    assert {:ok, result} =
             ToolExecutor.execute(
               %{
                 "thread_id" => "t1",
                 "to" => "a@b.test",
                 "subject" => "Re: Hi",
                 "body" => "Sounds good",
                 "in_reply_to" => "<msg-1@mail>",
                 "references" => "<msg-1@mail>"
               },
               gmail_context(plug),
               "gmail",
               %{"name" => "gmail_reply_to_thread", "read_only" => false}
             )

    assert result.success == true
    assert_received {:gmail_write, "/gmail/v1/users/me/messages/send", body}
    decoded = Jason.decode!(body)
    assert decoded["threadId"] == "t1"
    raw = Base.url_decode64!(decoded["raw"], padding: false)
    assert raw =~ "In-Reply-To: <msg-1@mail>"
    assert raw =~ "References: <msg-1@mail>"
    assert raw =~ "Sounds good"
  end

  test "modifies message labels (mark read = remove UNREAD)" do
    plug = gmail_write_plug(self(), %{"id" => "m1", "labelIds" => ["INBOX"]})

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"id" => "m1", "remove_label_ids" => ["UNREAD"]},
               gmail_context(plug),
               "gmail",
               gmail_tool("gmail_modify_message_labels")
             )

    assert result.success == true
    assert_received {:gmail_write, "/gmail/v1/users/me/messages/m1/modify", body}
    assert Jason.decode!(body)["removeLabelIds"] == ["UNREAD"]
  end

  test "trashes and untrashes a message" do
    parent = self()

    plug = fn conn ->
      send(parent, {:gmail_write, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "m1"}))
    end

    context = gmail_context(plug)

    assert {:ok, trashed} =
             ToolExecutor.execute(
               %{"id" => "m1"},
               context,
               "gmail",
               gmail_tool("gmail_trash_message")
             )

    assert trashed.success == true
    assert_received {:gmail_write, "/gmail/v1/users/me/messages/m1/trash"}

    assert {:ok, restored} =
             ToolExecutor.execute(
               %{"id" => "m1"},
               context,
               "gmail",
               gmail_tool("gmail_untrash_message")
             )

    assert restored.success == true
    assert_received {:gmail_write, "/gmail/v1/users/me/messages/m1/untrash"}
  end

  test "creates a Gmail label" do
    plug = gmail_write_plug(self(), %{"id" => "Label_1", "name" => "Receipts"})

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"name" => "Receipts"},
               gmail_context(plug),
               "gmail",
               gmail_tool("gmail_create_label")
             )

    assert result.success == true
    assert_received {:gmail_write, "/gmail/v1/users/me/labels", body}
    assert Jason.decode!(body)["name"] == "Receipts"
  end

  defp calendar_context(plug) do
    %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_calendar:primary" -> {:ok, "tok"} end,
      plugin_granted_scopes_getter: fn _ -> @calendar_scopes end
    }
  end

  defp cal_tool(name), do: plugin_tool("google_calendar", name)

  # Load a tool's real (now v2/declarative) manifest entry so tests exercise the
  # migrated template path, not a hand-written inline tool.
  defp plugin_tool(plugin_name, tool_name) do
    {:ok, plugins} = FermixCore.Plugins.Registry.list()
    plugin = Enum.find(plugins, &(&1.name == plugin_name))
    Enum.find(plugin.tools, &(&1["name"] == tool_name))
  end

  test "updates an event with a partial patch" do
    parent = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:cal, conn.method, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "evt-1", "summary" => "Renamed"}))
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"event_id" => "evt-1", "summary" => "Renamed"},
               calendar_context(plug),
               "google_calendar",
               cal_tool("google_calendar_update_event")
             )

    assert result.success == true
    assert_received {:cal, "PATCH", "/calendar/v3/calendars/primary/events/evt-1", raw}
    assert Jason.decode!(raw)["summary"] == "Renamed"
  end

  test "deletes an event and reports success on an empty 204" do
    parent = self()

    plug = fn conn ->
      send(parent, {:cal, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 204, "")
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"event_id" => "evt-1"},
               calendar_context(plug),
               "google_calendar",
               cal_tool("google_calendar_delete_event")
             )

    assert result.success == true
    # the interpreter maps an empty 204 to an explicit empty-success result
    assert Jason.decode!(result.output) == %{}
    assert_received {:cal, "DELETE", "/calendar/v3/calendars/primary/events/evt-1"}
  end

  test "responds to an invite by patching the self attendee and preserving the rest" do
    parent = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:cal, conn.method, conn.request_path, raw})

      body =
        case conn.method do
          "GET" ->
            %{
              "id" => "evt-1",
              "attendees" => [
                %{"email" => "other@x.test", "responseStatus" => "accepted"},
                %{"email" => "me@x.test", "self" => true, "responseStatus" => "needsAction"}
              ]
            }

          "PATCH" ->
            %{"id" => "evt-1"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"event_id" => "evt-1", "response_status" => "accepted"},
               calendar_context(plug),
               "google_calendar",
               %{"name" => "google_calendar_respond_to_event", "read_only" => false}
             )

    assert result.success == true
    assert_received {:cal, "GET", "/calendar/v3/calendars/primary/events/evt-1", _get_body}
    assert_received {:cal, "PATCH", "/calendar/v3/calendars/primary/events/evt-1", patch}
    attendees = Jason.decode!(patch)["attendees"]
    assert Enum.find(attendees, & &1["self"])["responseStatus"] == "accepted"
    assert Enum.any?(attendees, &(&1["email"] == "other@x.test"))
  end

  test "rejects an invalid RSVP response_status without calling the provider" do
    parent = self()

    plug = fn conn ->
      send(parent, {:cal, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 200, "{}")
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"event_id" => "evt-1", "response_status" => "maybe"},
               calendar_context(plug),
               "google_calendar",
               %{"name" => "google_calendar_respond_to_event", "read_only" => false}
             )

    assert result.success == false
    assert result.error =~ "response_status must be"
    refute_received {:cal, _method, _path}
  end

  test "moves an event to another calendar" do
    parent = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {:cal, conn.method, conn.request_path, conn.query_params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "evt-1"}))
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"event_id" => "evt-1", "destination_calendar_id" => "cal-2"},
               calendar_context(plug),
               "google_calendar",
               cal_tool("google_calendar_move_event")
             )

    assert result.success == true
    assert_received {:cal, "POST", "/calendar/v3/calendars/primary/events/evt-1/move", params}
    assert params["destination"] == "cal-2"
  end

  @drive_scopes ["https://www.googleapis.com/auth/drive"]

  defp drive_context(plug) do
    %{
      plugin_url_guard: fn _ -> :ok end,
      plugin_req_options: [plug: plug],
      plugin_token_getter: fn "google_drive:primary" -> {:ok, "tok"} end,
      plugin_granted_scopes_getter: fn _ -> @drive_scopes end
    }
  end

  defp drive_tool(name), do: plugin_tool("google_drive", name)

  test "creates a Drive folder" do
    parent = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:drive, conn.method, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "folder-1"}))
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"name" => "Receipts"},
               drive_context(plug),
               "google_drive",
               drive_tool("google_drive_create_folder")
             )

    assert result.success == true
    assert_received {:drive, "POST", "/drive/v3/files", raw}
    decoded = Jason.decode!(raw)
    assert decoded["name"] == "Receipts"
    assert decoded["mimeType"] == "application/vnd.google-apps.folder"
  end

  test "uploads a text file via multipart" do
    parent = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:drive, conn.method, conn.request_path, conn.query_params, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "file-9", "name" => "notes.txt"}))
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"name" => "notes.txt", "content" => "hello world"},
               drive_context(plug),
               "google_drive",
               %{"name" => "google_drive_upload_file", "read_only" => false}
             )

    assert result.success == true
    assert_received {:drive, "POST", "/upload/drive/v3/files", params, raw}
    assert params["uploadType"] == "multipart"
    assert raw =~ "application/json"
    assert raw =~ "notes.txt"
    assert raw =~ "hello world"
  end

  test "renames a Drive file" do
    parent = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:drive, conn.method, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "file-1", "name" => "New Name"}))
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"file_id" => "file-1", "name" => "New Name"},
               drive_context(plug),
               "google_drive",
               drive_tool("google_drive_update_file")
             )

    assert result.success == true
    assert_received {:drive, "PATCH", "/drive/v3/files/file-1", raw}
    assert Jason.decode!(raw)["name"] == "New Name"
  end

  test "moves a Drive file between folders" do
    parent = self()

    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(parent, {:drive, conn.method, conn.request_path, conn.query_params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "file-1"}))
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"file_id" => "file-1", "add_parent_id" => "dest", "remove_parent_id" => "src"},
               drive_context(plug),
               "google_drive",
               drive_tool("google_drive_move_file")
             )

    assert result.success == true
    assert_received {:drive, "PATCH", "/drive/v3/files/file-1", params}
    assert params["addParents"] == "dest"
    assert params["removeParents"] == "src"
  end

  test "copies a Drive file" do
    parent = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:drive, conn.method, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "file-2", "name" => "Copy"}))
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"file_id" => "file-1", "name" => "Copy"},
               drive_context(plug),
               "google_drive",
               drive_tool("google_drive_copy_file")
             )

    assert result.success == true
    assert_received {:drive, "POST", "/drive/v3/files/file-1/copy", raw}
    assert Jason.decode!(raw)["name"] == "Copy"
  end

  test "trashes a Drive file" do
    parent = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:drive, conn.method, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "file-1", "trashed" => true}))
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"file_id" => "file-1"},
               drive_context(plug),
               "google_drive",
               %{
                 "name" => "google_drive_trash_file",
                 "read_only" => false
               }
             )

    assert result.success == true
    assert_received {:drive, "PATCH", "/drive/v3/files/file-1", raw}
    assert Jason.decode!(raw)["trashed"] == true
  end

  test "permanently deletes a Drive file on an empty 204" do
    parent = self()

    plug = fn conn ->
      send(parent, {:drive, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 204, "")
    end

    assert {:ok, result} =
             ToolExecutor.execute(
               %{"file_id" => "file-1"},
               drive_context(plug),
               "google_drive",
               %{
                 "name" => "google_drive_delete_file",
                 "read_only" => false
               }
             )

    assert result.success == true
    assert Jason.decode!(result.output) == %{"ok" => true}
    assert_received {:drive, "DELETE", "/drive/v3/files/file-1"}
  end

  describe "declarative tools (request template → Http.Interpreter)" do
    # A tool carrying a `request` template routes through the interpreter +
    # the executor's auth/refresh/plug seam, instead of hardcoded dispatch.
    # (google_calendar supplies auth/scopes; the tool map itself is v2-shaped.)
    defp declarative_tool do
      %{
        "name" => "google_calendar_search_events",
        "read_only" => true,
        "requires_scopes" => ["https://www.googleapis.com/auth/calendar.readonly"],
        "rail" => "http",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "calendar_id" => %{"type" => "string", "default" => "primary"},
            "max_results" => %{"type" => "integer", "default" => 10}
          }
        },
        "request" => %{
          "method" => "GET",
          "url" => "https://www.googleapis.com/calendar/v3/calendars/{calendar_id}/events",
          "query" => %{
            "q" => "{query}",
            "maxResults" => "{max_results}",
            "singleEvents" => "true"
          }
        }
      }
    end

    test "executes through the interpreter and shapes the request from the template" do
      parent = self()

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(parent, {:declarative, conn.request_path, conn.query_params, auth_header(conn)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
      end

      context = %{
        plugin_url_guard: fn _ -> :ok end,
        plugin_req_options: [plug: plug],
        plugin_token_getter: fn "google_calendar:primary" -> {:ok, "tok"} end,
        plugin_granted_scopes_getter: fn _ ->
          ["https://www.googleapis.com/auth/calendar.readonly"]
        end
      }

      assert {:ok, result} =
               ToolExecutor.execute(
                 %{"query" => "standup"},
                 context,
                 "google_calendar",
                 declarative_tool()
               )

      assert result.success == true
      assert Jason.decode!(result.output) == %{"items" => []}
      # path uses the materialized default calendar_id=primary; query carries
      # the interpolated value, the literal, and the default max_results.
      assert_received {:declarative, "/calendar/v3/calendars/primary/events", params,
                       "Bearer tok"}

      assert params["q"] == "standup"
      assert params["singleEvents"] == "true"
      assert params["maxResults"] == "10"
    end

    test "refreshes the token once on a 401 for a read-only declarative tool" do
      parent = self()

      plug = fn conn ->
        token = auth_header(conn)
        send(parent, {:declarative_auth, token})

        case token do
          "Bearer old" ->
            Plug.Conn.send_resp(conn, 401, "")

          "Bearer fresh" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(%{"items" => []}))
        end
      end

      context = %{
        plugin_url_guard: fn _ -> :ok end,
        plugin_req_options: [plug: plug],
        plugin_token_getter: fn "google_calendar:primary" -> {:ok, "old"} end,
        plugin_token_refresher: fn "google_calendar:primary" -> {:ok, "fresh"} end,
        plugin_granted_scopes_getter: fn _ ->
          ["https://www.googleapis.com/auth/calendar.readonly"]
        end
      }

      assert {:ok, result} =
               ToolExecutor.execute(
                 %{"query" => "x"},
                 context,
                 "google_calendar",
                 declarative_tool()
               )

      assert result.success == true
      assert_received {:declarative_auth, "Bearer old"}
      assert_received {:declarative_auth, "Bearer fresh"}
    end

    test "keeps Google's bespoke 403 scope classification through the interpreter" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "secret-token rejected",
              "details" => [%{"reason" => "ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]
            }
          })
        )
      end

      context = %{
        plugin_url_guard: fn _ -> :ok end,
        plugin_req_options: [plug: plug],
        plugin_token_getter: fn "google_calendar:primary" -> {:ok, "secret-token"} end,
        plugin_granted_scopes_getter: fn _ ->
          ["https://www.googleapis.com/auth/calendar.readonly"]
        end
      }

      assert {:ok, result} =
               ToolExecutor.execute(
                 %{"query" => "x"},
                 context,
                 "google_calendar",
                 declarative_tool()
               )

      assert result.success == false
      # the bespoke message is preserved (not the interpreter's generic prose)
      assert result.error =~ "missing a required scope"
      assert result.error =~ "fermix plugins auth reauthorize google_calendar"
      refute result.error =~ "secret-token"
    end

    test "blocks private-address URLs before any transport (SSRF floor)" do
      parent = self()

      plug = fn conn ->
        send(parent, :transport_reached)
        Plug.Conn.send_resp(conn, 200, "should never be reached")
      end

      # No :plugin_url_guard stub — the real Net.Guard runs. An IP-literal
      # host is validated without DNS, so this stays hermetic.
      context = %{
        plugin_req_options: [plug: plug],
        plugin_token_getter: fn "google_calendar:primary" -> {:ok, "tok"} end,
        plugin_granted_scopes_getter: fn _ ->
          ["https://www.googleapis.com/auth/calendar.readonly"]
        end
      }

      tool =
        put_in(declarative_tool(), ["request", "url"], "https://169.254.169.254/latest/meta-data")

      assert {:ok, result} =
               ToolExecutor.execute(%{"query" => "x"}, context, "google_calendar", tool)

      assert result.success == false
      assert result.error =~ "blocked_url"
      refute_received :transport_reached
    end

    test "surfaces the refresh failure reason instead of a synthetic 401" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 401, "") end

      context = %{
        plugin_url_guard: fn _ -> :ok end,
        plugin_req_options: [plug: plug],
        plugin_token_getter: fn "google_calendar:primary" -> {:ok, "old"} end,
        plugin_token_refresher: fn "google_calendar:primary" -> {:error, :network_unreachable} end,
        plugin_granted_scopes_getter: fn _ ->
          ["https://www.googleapis.com/auth/calendar.readonly"]
        end
      }

      assert {:ok, result} =
               ToolExecutor.execute(
                 %{"query" => "x"},
                 context,
                 "google_calendar",
                 declarative_tool()
               )

      assert result.success == false
      assert result.error =~ "token_refresh_failed"
      assert result.error =~ "network_unreachable"
    end
  end

  defp auth_header(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [value | _] -> value
      [] -> nil
    end
  end
end
