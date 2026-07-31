defmodule FermixCore.Tools.ReactTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.React

  describe "metadata" do
    test "is a channel-category builtin named react" do
      assert React.name() == "react"
      assert React.category() == :channel
    end
  end

  describe "advertise?/1" do
    test "advertises only when the turn resolved a reaction capability" do
      assert React.advertise?(%{reaction_spec: %{emoji_set: :any}})
      assert React.advertise?(%{reaction_spec: %{emoji_set: ["👍", "🎉"]}})
    end

    test "hides the tool on a channel with no reaction capability" do
      refute React.advertise?(%{reaction_spec: nil})
      refute React.advertise?(%{})
    end
  end

  describe "dynamic_parameters/1" do
    test "constrains emoji to an enum of the channel's allowed set (restricted)" do
      schema = React.dynamic_parameters(%{reaction_spec: %{emoji_set: ["👍", "🎉", "🙏"]}})

      assert schema.required == ["emoji"]
      assert schema.properties.emoji.enum == ["👍", "🎉", "🙏"]
    end

    test "leaves emoji free-form on an any-emoji channel" do
      schema = React.dynamic_parameters(%{reaction_spec: %{emoji_set: :any}})

      assert schema.properties.emoji.type == "string"
      refute Map.has_key?(schema.properties.emoji, :enum)
    end

    test "falls back to a free-form string when no reaction spec is present" do
      schema = React.dynamic_parameters(%{})

      assert schema.properties.emoji.type == "string"
      refute Map.has_key?(schema.properties.emoji, :enum)
    end
  end

  describe "execute/2" do
    test "delivers a {:react, emoji} part through the channel reply port" do
      test_pid = self()

      context = %{
        agent_name: "main",
        reply_fn: fn part ->
          send(test_pid, {:reply, part})
          :ok
        end
      }

      assert {:ok, %{success: true, output: output, error: nil}} =
               React.execute(%{"emoji" => "🙏"}, context)

      assert output =~ "🙏"
      assert_receive {:reply, {:react, "🙏"}}
    end

    test "fails loudly when no channel reply function is available" do
      assert {:ok, %{success: false, error: "react requires a channel reply context"}} =
               React.execute(%{"emoji" => "👍"}, %{agent_name: "main"})
    end

    test "requires an emoji argument" do
      context = %{agent_name: "main", reply_fn: fn _ -> :ok end}

      assert {:ok, %{success: false, error: "Missing required parameter: emoji"}} =
               React.execute(%{}, context)
    end

    test "surfaces a channel reaction-unsupported error as a tool error, never a silent text swap" do
      context = %{
        agent_name: "main",
        reply_fn: fn {:react, _emoji} -> {:error, :reaction_unsupported} end
      }

      assert {:ok, %{success: false, error: error}} = React.execute(%{"emoji" => "👍"}, context)
      assert error =~ "Failed to react"
      assert error =~ "reaction_unsupported"
    end

    test "emits tool execution telemetry" do
      handler_id = "react-telemetry-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:fermix, :tool, :exec],
          fn event, measurements, metadata, pid ->
            if self() == pid do
              send(pid, {:telemetry, event, measurements, metadata})
            end
          end,
          self()
        )

      try do
        context = %{agent_name: "main", reply_fn: fn _ -> :ok end}
        assert {:ok, %{success: true}} = React.execute(%{"emoji" => "👍"}, context)

        assert_receive {:telemetry, [:fermix, :tool, :exec], %{duration_ms: duration_ms},
                        %{tool: "react", agent: "main", success: true}}

        assert is_integer(duration_ms) and duration_ms >= 0
      after
        :telemetry.detach(handler_id)
      end
    end
  end
end
