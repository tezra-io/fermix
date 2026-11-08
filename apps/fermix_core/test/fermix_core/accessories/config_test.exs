defmodule FermixCore.Accessories.ConfigTest do
  @moduledoc """
  `[fermix_channels.accessories]`: one boolean, off when the section says
  nothing, with the string→atom normalizer and its inverse the persist path
  writes (the "Config round-trips" rule).

  async: false: `current/0` reads application environment, which every app
  in the umbrella's one test VM shares; the case that sets it restores it.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Accessories.Config

  describe "normalize/1" do
    test "a missing or empty section is off" do
      for config <- [nil, [], %{}] do
        assert Config.normalize(config) == %Config{enabled?: false}, inspect(config)
      end
    end

    test "reads the file's string keys" do
      assert Config.normalize(%{"enabled" => true}) == %Config{enabled?: true}
      assert Config.normalize(%{"enabled" => false}) == %Config{enabled?: false}
    end

    test "reads the app-env atom keys, as a keyword or a map" do
      assert Config.normalize(enabled: true) == %Config{enabled?: true}
      assert Config.normalize(enabled: false) == %Config{enabled?: false}
      assert Config.normalize(%{enabled: true}) == %Config{enabled?: true}
    end

    test "is idempotent over its own output and over to_keyword/1's" do
      for config <- [nil, [], %{"enabled" => true}, %{"enabled" => false}, [enabled: true]] do
        normalized = Config.normalize(config)

        assert Config.normalize(normalized) == normalized, inspect(config)
        assert Config.normalize(Config.to_keyword(normalized)) == normalized, inspect(config)
      end
    end

    test "refuses an enabled that is not a boolean, naming the key" do
      for value <- ["true", "yes", 1, 0, nil, :true_ish, ["true"]] do
        error =
          assert_raise ArgumentError, fn ->
            Config.normalize(%{"enabled" => value})
          end

        assert error.message =~ "fermix_channels.accessories.enabled must be true or false"
        assert error.message =~ inspect(value)
      end

      assert_raise ArgumentError, ~r/fermix_channels\.accessories\.enabled/, fn ->
        Config.normalize(enabled: "on")
      end
    end

    # A key a later phase adds (Phase B's network keys) must not refuse an
    # older daemon's boot after a rollback.
    test "ignores keys it does not know" do
      assert Config.normalize(%{"enabled" => true, "bind" => "0.0.0.0", "port" => 4_100}) ==
               %Config{enabled?: true}

      assert Config.normalize(transport: "tcp") == %Config{enabled?: false}
    end

    test "refuses a section that is not a table" do
      for config <- ["enabled", 1, true, [:enabled], %URI{}] do
        assert_raise ArgumentError, ~r/fermix_channels\.accessories is not a table/, fn ->
          Config.normalize(config)
        end
      end
    end
  end

  describe "to_keyword/1" do
    test "omits the default, so a home that never turned it on gains no section" do
      assert Config.to_keyword(%Config{enabled?: false}) == []
    end

    test "writes the switch when it is on" do
      assert Config.to_keyword(%Config{enabled?: true}) == [enabled: true]
    end

    test "is the inverse of normalize/1 in both directions" do
      for keyword <- [[], [enabled: true]] do
        assert keyword |> Config.normalize() |> Config.to_keyword() == keyword
      end

      for config <- [%Config{enabled?: false}, %Config{enabled?: true}] do
        assert config |> Config.to_keyword() |> Config.normalize() == config
      end
    end
  end

  describe "current/0 and enabled?/0" do
    setup do
      previous = Application.fetch_env(:fermix_channels, :accessories)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:fermix_channels, :accessories, value)
          :error -> Application.delete_env(:fermix_channels, :accessories)
        end
      end)
    end

    test "is off when application environment has no section" do
      Application.delete_env(:fermix_channels, :accessories)

      assert Config.current() == %Config{enabled?: false}
      refute Config.enabled?()
    end

    test "reads the section application environment holds" do
      Application.put_env(:fermix_channels, :accessories, enabled: true)

      assert Config.current() == %Config{enabled?: true}
      assert Config.enabled?()

      Application.put_env(:fermix_channels, :accessories, [])

      assert Config.current() == %Config{enabled?: false}
      refute Config.enabled?()
    end

    test "refuses a bad value in application environment by name" do
      Application.put_env(:fermix_channels, :accessories, enabled: "yes")

      assert_raise ArgumentError, ~r/fermix_channels\.accessories\.enabled/, fn ->
        Config.current()
      end
    end
  end
end
