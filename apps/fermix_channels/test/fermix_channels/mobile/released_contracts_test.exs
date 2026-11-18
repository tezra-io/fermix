defmodule FermixChannels.Mobile.ReleasedContractsTest do
  @moduledoc """
  A phone, or a computer linked to its server, that has not updated still
  works against this engine: for every release with a snapshot
  (`FermixTestSupport.ReleasedContracts`), its mobile protocol still holds
  here. The management and Realtime halves are `FermixCore.ReleasedContractsTest`.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Protocol
  alias FermixTestSupport.ReleasedContracts

  @priv Application.app_dir(:fermix_core, "priv")

  test "a released app's version is inside this engine's window" do
    {minimum, maximum} = Protocol.supported_version_range()

    for release <- ReleasedContracts.releases() do
      schema =
        ReleasedContracts.json(ReleasedContracts.dir(release), "mobile/protocol.schema.json")

      version = schema["x-protocol-version"]

      assert version in minimum..maximum,
             "#{release}'s apps speak mobile #{version}; this engine serves #{minimum} to #{maximum}"
    end
  end

  test "every frame a released app was built to send still decodes" do
    for release <- ReleasedContracts.releases(),
        {header, bytes} <- client_frames(ReleasedContracts.dir(release)) do
      assert {:ok, %{type: type}} = Protocol.decode_client_frame(frame(header, bytes)),
             "#{release}'s #{header["t"]} frame no longer decodes"

      assert type == header["t"]
    end
  end

  test "every frame still carries what a released app reads" do
    current = server_samples(@priv)

    for release <- ReleasedContracts.releases() do
      breaks =
        ReleasedContracts.shape_breaks(server_samples(ReleasedContracts.dir(release)), current)

      assert breaks == [], "#{release}'s apps can no longer read:\n" <> Enum.join(breaks, "\n")
    end
  end

  defp client_frames(root) do
    events = for header <- jsonl(root, "client_events"), do: {header, <<>>}

    binary =
      for fixture <- jsonl(root, "client_binary_frames"),
          do: {fixture["header"], Base.decode64!(fixture["bytes_b64"])}

    events ++ binary
  end

  defp server_samples(root) do
    events = for header <- jsonl(root, "server_events"), do: {header["t"], header}

    binary =
      for fixture <- jsonl(root, "server_binary_frames"),
          do: {fixture["header"]["t"], fixture["header"]}

    events ++ binary
  end

  defp jsonl(root, name), do: ReleasedContracts.jsonl(root, "mobile/fixtures/#{name}.jsonl")

  # The wire's frame: the header's length, the header, then its raw bytes.
  defp frame(header, bytes) do
    json = Jason.encode!(header)
    <<byte_size(json)::32, json::binary, bytes::binary>>
  end
end
