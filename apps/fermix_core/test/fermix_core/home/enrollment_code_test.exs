defmodule FermixCore.Home.EnrollmentCodeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.EnrollmentCode

  @facts %{
    secret: :binary.copy(<<0x5A>>, 32),
    gateway_pk: :binary.copy(<<0x3C>>, 32),
    node_id: String.duplicate("4f", 32),
    relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
    relays_rev: "0123456789abcdef",
    name: "orchard-mini",
    expires_at: ~U[2031-05-04 10:20:30Z]
  }

  test "a code carries the window's facts and reads back the same, trimmed" do
    assert {:ok, "fxenroll1." <> body = code} = EnrollmentCode.encode(@facts)
    assert Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, body)
    assert byte_size(code) in 42..2_048

    assert {:ok, decoded} = EnrollmentCode.decode("  " <> code <> "\n")
    assert decoded == @facts
  end

  test "anything else is refused by what is wrong, never echoed" do
    {:ok, code} = EnrollmentCode.encode(@facts)

    assert {:error, {:invalid_code, "prefix"}} = EnrollmentCode.decode("fxpair1." <> code)
    assert {:error, {:invalid_code, "base64url"}} = EnrollmentCode.decode("fxenroll1.!!!")
    assert {:error, {:invalid_code, "json"}} = EnrollmentCode.decode(wrap("not json"))
    assert {:error, {:invalid_code, "v"}} = EnrollmentCode.decode(wrap(~s({"v":2})))

    bad_node = json(%{"node_id" => "XYZ"})
    assert {:error, {:invalid_code, "node_id"}} = EnrollmentCode.decode(wrap(bad_node))

    short_secret = json(%{"secret" => Base.encode64("short")})
    assert {:error, {:invalid_code, "secret"}} = EnrollmentCode.decode(wrap(short_secret))

    no_relays = json(%{"relays" => []})
    assert {:error, {:invalid_code, "relays"}} = EnrollmentCode.decode(wrap(no_relays))

    plain_http = json(%{"relays" => [%{"url" => "http://relay.invalid/", "quic_port" => 1}]})
    assert {:error, {:invalid_code, "relays"}} = EnrollmentCode.decode(wrap(plain_http))

    control = json(%{"name" => "a\nb"})
    assert {:error, {:invalid_code, "name"}} = EnrollmentCode.decode(wrap(control))
    assert {:error, {:invalid_code, "code"}} = EnrollmentCode.decode(nil)
  end

  test "a code past the bound the first-boot script holds is refused" do
    relays =
      for n <- 1..8,
          do: %{
            "url" => "https://#{String.duplicate("r", 200)}#{n}.invalid/",
            "quic_port" => 7842
          }

    assert {:error, :code_too_long} =
             EnrollmentCode.encode(%{@facts | relays: relays, name: String.duplicate("n", 128)})
  end

  defp json(overrides) do
    %{
      "v" => 1,
      "secret" => Base.encode64(@facts.secret),
      "gateway_pk" => Base.encode64(@facts.gateway_pk),
      "node_id" => @facts.node_id,
      "relays" => @facts.relays,
      "relays_rev" => @facts.relays_rev,
      "name" => @facts.name,
      "expires_at" => "2031-05-04T10:20:30Z"
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp wrap(json), do: "fxenroll1." <> Base.url_encode64(json, padding: false)
end
