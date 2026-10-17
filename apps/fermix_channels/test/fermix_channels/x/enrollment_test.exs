defmodule FermixChannels.X.EnrollmentTest do
  # The enrollment calls (priv/connect/PROTOCOL.md §2) against a stand-in
  # Connect: a function plug that hands each request to the test and answers
  # with the contract's own fixtures, so the client is held to the shapes
  # Connect is held to. The instance key lives under a home of the test's own.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.X.Enrollment
  alias FermixChannels.X.Pairing
  alias FermixCore.Net.Egress
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.WireSchema

  @priv_dir Application.app_dir(:fermix_core, "priv/connect")
  # The fixtures' own origin, which their confirmation link is on.
  @origin "https://connect.fermix.ai"
  @enrollment_id "enr_5c1e9a3b7d2f"
  @instance_id "ins_7f3c2a9e1b4d"

  setup do
    home = SafeRm.make_tmp_dir!("x-enrollment")
    on_exit(fn -> SafeRm.rm_rf(home) end)
    pairing = [root: home]
    {:ok, public_key} = Pairing.ensure_key(pairing)

    schema = @priv_dir |> Path.join("protocol.schema.json") |> File.read!() |> Jason.decode!()

    fixtures =
      @priv_dir
      |> Path.join("fixtures/enrollment.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        fixture = Jason.decode!(line)
        {fixture["name"], fixture}
      end)

    proof = fixtures |> Map.fetch!("enrollment_prove_request") |> Map.fetch!("value")

    %{
      pairing: pairing,
      public_key: public_key,
      schema: schema,
      fixtures: fixtures,
      code: proof["code"],
      verifier: proof["code_verifier"]
    }
  end

  # Every request reaches the test as `{:connect, method, path, headers, body}`
  # and is answered `status` with `body` as JSON (or as raw text).
  defp connect(test_pid, status, body) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:connect, conn.method, conn.request_path, conn.req_headers, raw})
      respond(conn, status, body)
    end
  end

  defp respond(conn, status, {:raw, text}), do: Plug.Conn.send_resp(conn, status, text)

  defp respond(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp opts(ctx, plug, extra \\ []) do
    Keyword.merge(
      [pairing: ctx.pairing, egress: %Egress{}, req_options: [plug: plug]],
      extra
    )
  end

  defp answer(ctx, name), do: ctx.fixtures |> Map.fetch!(name) |> Map.fetch!("value")

  defp assert_contract(value, def_name, ctx),
    do: assert(WireSchema.errors(value, WireSchema.ref(def_name), ctx.schema) == [])

  describe "create/3" do
    test "publishes the key under the label and reads the contract's answer", ctx do
      plug = connect(self(), 201, answer(ctx, "enrollment_create_answer"))

      assert {:ok, created} = Enrollment.create(@origin, "Studio Mac", opts(ctx, plug))

      assert created.enrollment_id == @enrollment_id
      assert created.confirm_url == "https://connect.fermix.ai/confirm/frS-OLNTPoRzRh9g6Vk4QCCF"
      assert created.expires_at == ~U[2026-10-16 05:00:00Z]

      assert_received {:connect, "POST", "/v1/enrollments", headers, raw}
      assert {"content-type", "application/json"} in headers
      body = Jason.decode!(raw)
      assert_contract(body, "enrollmentCreateRequest", ctx)

      assert body == %{
               "protocol_version" => 1,
               "public_key" => Base.url_encode64(ctx.public_key, padding: false),
               "key_id" => Pairing.key_id(ctx.public_key),
               "label" => "Studio Mac"
             }
    end

    test "an answer in another shape is an unsupported protocol", ctx do
      plug = connect(self(), 201, %{"enrollment_id" => @enrollment_id})

      log =
        capture_log(fn ->
          assert {:error, :unsupported_protocol} =
                   Enrollment.create(@origin, "Studio Mac", opts(ctx, plug))
        end)

      assert log =~ "a shape the contract does not name"
    end

    # The engine appends the authorization request to the link, so a link
    # carrying a query of its own, or one on another host, is not the
    # contract's `<origin>/confirm/<token>`, and nothing would open it.
    test "a confirmation link that is not this origin's confirm path is refused", ctx do
      answer = answer(ctx, "enrollment_create_answer")

      for url <- [
            answer["confirm_url"] <> "?next=1",
            answer["confirm_url"] <> "#top",
            "https://connect.fermix.example/confirm/frS-OLNTPoRzRh9g6Vk4QCCF",
            "https://connect.fermix.ai/pair/frS-OLNTPoRzRh9g6Vk4QCCF",
            "https://connect.fermix.ai/confirm/",
            "https://connect.fermix.ai/confirm/" <> String.duplicate("a", 1_024)
          ] do
        plug = connect(self(), 201, Map.put(answer, "confirm_url", url))

        capture_log(fn ->
          assert {:error, :unsupported_protocol} =
                   Enrollment.create(@origin, "Studio Mac", opts(ctx, plug)),
                 "#{url} was taken as the confirmation link"
        end)
      end
    end

    test "the create answer is open to a field the contract adds", ctx do
      extended =
        Map.put(answer(ctx, "enrollment_create_answer"), "state", "awaiting_confirmation")

      plug = connect(self(), 201, extended)

      assert {:ok, %{enrollment_id: @enrollment_id}} =
               Enrollment.create(@origin, "Studio Mac", opts(ctx, plug))
    end

    test "Connect naming the version is an unsupported protocol", ctx do
      fixture = Map.fetch!(ctx.fixtures, "enrollment_create_unsupported_version")
      plug = connect(self(), fixture["status"], fixture["value"])

      capture_log(fn ->
        assert {:error, :unsupported_protocol} =
                 Enrollment.create(@origin, "Studio Mac", opts(ctx, plug))
      end)
    end

    test "a contract error is Connect refusing, with its code", ctx do
      for name <- ~w(enrollment_create_rate_limited enrollment_create_invalid_request
                     enrollment_create_internal_error) do
        fixture = Map.fetch!(ctx.fixtures, name)
        plug = connect(self(), fixture["status"], fixture["value"])
        code = fixture["value"]["error"]["code"]

        capture_log(fn ->
          assert {:error, {:connect_refused, ^code}} =
                   Enrollment.create(@origin, "Studio Mac", opts(ctx, plug))
        end)
      end
    end

    test "a 5xx without the contract's body is Connect out of reach", ctx do
      plug = connect(self(), 502, {:raw, "<html>bad gateway</html>"})

      capture_log(fn ->
        assert {:error, :connect_unreachable} =
                 Enrollment.create(@origin, "Studio Mac", opts(ctx, plug))
      end)
    end

    test "a 4xx without the contract's body, or a redirect, is an unsupported protocol", ctx do
      for status <- [404, 302] do
        plug = connect(self(), status, {:raw, "not here"})

        capture_log(fn ->
          assert {:error, :unsupported_protocol} =
                   Enrollment.create(@origin, "Studio Mac", opts(ctx, plug))
        end)
      end
    end

    test "a transport failure is Connect out of reach", ctx do
      plug = fn conn -> Req.Test.transport_error(conn, :econnrefused) end

      capture_log(fn ->
        assert {:error, :connect_unreachable} =
                 Enrollment.create(@origin, "Studio Mac", opts(ctx, plug))
      end)
    end

    test "with no instance key nothing is sent", ctx do
      SafeRm.rm!(Pairing.key_path(ctx.pairing))
      plug = connect(self(), 201, answer(ctx, "enrollment_create_answer"))

      assert {:error, {:key_unavailable, {:missing, _path}}} =
               Enrollment.create(@origin, "Studio Mac", opts(ctx, plug))

      refute_received {:connect, _method, _path, _headers, _body}
    end

    test "an origin, or a label, the contract cannot name is refused before anything is sent",
         ctx do
      plug = connect(self(), 201, answer(ctx, "enrollment_create_answer"))

      for origin <- ["http://connect.fermix.example", "https://connect.fermix.example/", "x"] do
        assert_raise ArgumentError, fn -> Enrollment.create(origin, "Mac", opts(ctx, plug)) end
      end

      for label <- ["", " padded ", "tab\there", String.duplicate("a", 65)] do
        assert_raise ArgumentError, fn -> Enrollment.create(@origin, label, opts(ctx, plug)) end
      end

      refute_received {:connect, _method, _path, _headers, _body}
    end
  end

  describe "label/1" do
    test "makes any host name a label the contract bounds" do
      assert Enrollment.label("Studio-Mac.local") == "Studio-Mac.local"
      assert Enrollment.label("  Sam's\u0000 Mac\n  ") == "Sam's Mac"
      assert Enrollment.label("") == "Fermix"
      assert Enrollment.label("\u2028\t ") == "Fermix"
      assert Enrollment.label(<<0xFF, "Mac">>) == "Mac"

      long = Enrollment.label(String.duplicate("é", 80))
      assert String.length(long) == 64
      assert Enrollment.label?(long)

      # A grapheme is never split to fit: a family emoji is seven code points.
      family = "👨‍👩‍👧‍👦"
      assert Enrollment.label(String.duplicate(family, 10)) == String.duplicate(family, 9)
    end
  end

  # There is no read of an enrollment: the installation learns the outcome
  # from its loopback, the proof's answer and its own clock (section 2.3).
  test "nothing reads an enrollment back" do
    refute function_exported?(Enrollment, :get, 3)
  end

  describe "code?/1" do
    test "is the contract's authorization code shape", ctx do
      assert Enrollment.code?(ctx.code)
      refute Enrollment.code?(binary_part(ctx.code, 0, 42))
      refute Enrollment.code?(ctx.code <> "A")
      refute Enrollment.code?(String.duplicate("+", 43))
      refute Enrollment.code?(nil)
    end
  end

  describe "prove/5" do
    test "signs the exact proof string and reads the record's fields", ctx do
      plug = connect(self(), 200, answer(ctx, "enrollment_prove_answer"))

      assert {:ok, proof} =
               Enrollment.prove(@origin, @enrollment_id, ctx.code, ctx.verifier, opts(ctx, plug))

      assert proof == %{
               instance_id: @instance_id,
               tenant_id: "1234567890",
               handle: "@sujeeth",
               key_generation: 1,
               tenant_generation: 1,
               connect_key_id: "c2026a",
               connect_public_key: "yLSZmrnsWsO8SscsSaEJgRceRdtpLJuPb46sJAyT_24"
             }

      assert_received {:connect, "POST", "/v1/enrollments/enr_5c1e9a3b7d2f/prove", _headers, raw}
      body = Jason.decode!(raw)
      assert_contract(body, "proveRequest", ctx)
      assert %{"code" => code, "code_verifier" => verifier} = body
      assert code == ctx.code and verifier == ctx.verifier

      {:ok, signature} = Base.url_decode64(body["signature"], padding: false)
      message = "fermix-connect-enroll|#{@origin}|#{@enrollment_id}|#{ctx.code}"
      assert Enrollment.enroll_message(@origin, @enrollment_id, ctx.code) == message
      assert Pairing.verify(message, signature, ctx.public_key)
    end

    test "the proof answer is closed: a field the contract does not name is refused", ctx do
      extended = Map.put(answer(ctx, "enrollment_prove_answer"), "plan", "pro")
      plug = connect(self(), 200, extended)

      capture_log(fn ->
        assert {:error, :unsupported_protocol} =
                 Enrollment.prove(
                   @origin,
                   @enrollment_id,
                   ctx.code,
                   ctx.verifier,
                   opts(ctx, plug)
                 )
      end)
    end

    test "Connect's refusals keep their codes", ctx do
      for name <- ~w(enrollment_prove_rejected enrollment_prove_already_active
                     enrollment_prove_tenant_already_paired enrollment_prove_key_already_paired) do
        fixture = Map.fetch!(ctx.fixtures, name)
        plug = connect(self(), fixture["status"], fixture["value"])
        code = fixture["value"]["error"]["code"]

        capture_log(fn ->
          assert {:error, {:connect_refused, ^code}} =
                   Enrollment.prove(
                     @origin,
                     @enrollment_id,
                     ctx.code,
                     ctx.verifier,
                     opts(ctx, plug)
                   )
        end)
      end
    end

    test "a code or a verifier that is not the contract's shape is never signed or sent",
         ctx do
      plug = connect(self(), 200, answer(ctx, "enrollment_prove_answer"))

      for {code, verifier} <- [
            {"short", ctx.verifier},
            {ctx.code <> "A", ctx.verifier},
            {ctx.code, String.duplicate("a", 42)},
            {ctx.code, String.duplicate("a", 129)},
            {ctx.code, String.duplicate("+", 43)}
          ] do
        assert_raise ArgumentError, fn ->
          Enrollment.prove(@origin, @enrollment_id, code, verifier, opts(ctx, plug))
        end
      end

      refute_received {:connect, _method, _path, _headers, _body}
    end
  end

  describe "delete_instance/3" do
    test "sends the signed headers of section 2.4", ctx do
      plug = connect(self(), 204, {:raw, ""})
      clock = fn -> ~U[2026-10-16 06:00:00.123456Z] end

      assert :ok =
               Enrollment.delete_instance(@origin, @instance_id, opts(ctx, plug, clock: clock))

      assert_received {:connect, "DELETE", "/v1/instances/ins_7f3c2a9e1b4d", headers, ""}
      headers = Map.new(headers)

      signed = %{
        "X-Fermix-Instance" => headers["x-fermix-instance"],
        "X-Fermix-Key-Id" => headers["x-fermix-key-id"],
        "X-Fermix-Timestamp" => headers["x-fermix-timestamp"],
        "X-Fermix-Signature" => headers["x-fermix-signature"]
      }

      assert_contract(signed, "signedRequestHeaders", ctx)
      assert signed["X-Fermix-Instance"] == @instance_id
      assert signed["X-Fermix-Key-Id"] == Pairing.key_id(ctx.public_key)
      assert signed["X-Fermix-Timestamp"] == "2026-10-16T06:00:00Z"

      message =
        "fermix-connect-request|#{@origin}|DELETE|/v1/instances/#{@instance_id}|2026-10-16T06:00:00Z"

      {:ok, signature} = Base.url_decode64(signed["X-Fermix-Signature"], padding: false)
      assert Pairing.verify(message, signature, ctx.public_key)
    end

    test "an unknown instance and a stale clock are Connect's refusals", ctx do
      for name <- ~w(instance_delete_unknown_instance instance_delete_stale_request) do
        fixture = Map.fetch!(ctx.fixtures, name)
        plug = connect(self(), fixture["status"], fixture["value"])
        code = fixture["value"]["error"]["code"]

        capture_log(fn ->
          assert {:error, {:connect_refused, ^code}} =
                   Enrollment.delete_instance(@origin, @instance_id, opts(ctx, plug))
        end)
      end
    end
  end
end
