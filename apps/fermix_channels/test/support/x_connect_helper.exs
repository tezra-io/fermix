defmodule FermixChannels.Test.XConnectHelper do
  @moduledoc """
  Fixtures for the X channel's tests: a stand-in Connect signing key, a
  pairing record that trusts it, the assignment example of
  `priv/connect/PROTOCOL.md` §4, compact JWS signing done by hand (so the
  verifier is checked against an independent encoder), and the fakes the pump
  talks to.

  `FakeClient` reports every frame the pump sends to the process named as the
  pump's `client:` as `{:to_connect, frame}`; `FakeAgent` hands each agent
  message the gateway delivers to its `agent_server:` as
  `{:agent_message, message}`.
  """

  alias FermixChannels.X.Pairing

  @kid "c2026a"
  @instance_id "ins_7f3c2a9e1b4d"
  @tenant_id "1234567890"

  defmodule FakeClient do
    @moduledoc false

    def send_receipt(server, id, outcome), do: report(server, {:receipt, id, outcome})
    def send_start(server, id), do: report(server, {:start, id})
    def send_result(server, frame), do: report(server, {:result, frame})
    def send_cancel_ack(server, id), do: report(server, {:cancel_ack, id})

    defp report(server, frame) do
      send(server, {:to_connect, frame})
      :ok
    end
  end

  defmodule FakeAgent do
    @moduledoc false

    def handle_message(message, server) do
      send(server, {:agent_message, message})
      :ok
    end
  end

  @spec kid() :: String.t()
  def kid, do: @kid

  @doc "A stand-in for Connect's assignment-signing key: `{public, seed}`."
  @spec connect_key() :: {binary(), binary()}
  def connect_key, do: :crypto.generate_key(:eddsa, :ed25519)

  @doc "A pairing record that trusts `connect_public` and names the §4 example's instance."
  @spec record(binary(), map()) :: Pairing.t()
  def record(connect_public, overrides \\ %{}) do
    struct!(
      Pairing,
      Map.merge(
        %{
          version: 1,
          origin: "https://connect.fermix.example",
          instance_id: @instance_id,
          tenant_id: @tenant_id,
          handle: "@sujeeth",
          key_id: "k3f9a1c2e7b4d05a8",
          key_generation: 1,
          tenant_generation: 1,
          connect_key_id: @kid,
          connect_public_key: Base.url_encode64(connect_public, padding: false),
          paired_at: "2026-10-16T05:00:00Z"
        },
        overrides
      )
    )
  end

  @doc "The §4 example payload, its digest computed, with `overrides` merged in."
  @spec payload(map()) :: map()
  def payload(overrides \\ %{}) do
    base = %{
      "protocol_version" => 1,
      "assignment_id" => "as_01j9x3k2m4n5p6q7",
      "interaction_id" => "ix_01j9x3k2m4n5p6q7",
      "tenant_id" => @tenant_id,
      "tenant_generation" => 1,
      "instance_id" => @instance_id,
      "key_generation" => 1,
      "bot_user_id" => "1987654321",
      "requester_x_user_id" => @tenant_id,
      "invoking_post_id" => "1845000000000000001",
      "conversation_id" => "1844999999999999990",
      "request_text" => "@FermixAI explain this",
      "request_sha256" => sha256_hex("@FermixAI explain this"),
      "context" => %{
        "posts" => [
          %{
            "id" => "1844999999999999990",
            "author_id" => "1122334455",
            "author_handle" => "@alice",
            "role" => "parent",
            "text" => "Cold starts dropped from 900 ms to 410 ms after the cache change.",
            "created_at" => "2026-10-16T04:58:00Z"
          },
          %{
            "id" => "1845000000000000001",
            "author_id" => @tenant_id,
            "author_handle" => "@sujeeth",
            "role" => "invoking",
            "text" => "@FermixAI explain this",
            "created_at" => "2026-10-16T04:59:00Z"
          }
        ],
        "truncated" => false
      },
      "issued_at" => "2026-10-16T05:00:00Z",
      "expires_at" => "2026-10-16T05:15:00Z"
    }

    Map.merge(base, overrides)
  end

  @doc "A compact JWS of `payload`, signed with `seed` under `header`."
  @spec sign(map(), binary(), map()) :: String.t()
  def sign(payload, seed, header \\ %{"alg" => "EdDSA", "kid" => @kid}) do
    input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(payload))
    input <> "." <> b64(:crypto.sign(:eddsa, :none, input, [seed, :ed25519]))
  end

  @spec sha256_hex(binary()) :: String.t()
  def sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
