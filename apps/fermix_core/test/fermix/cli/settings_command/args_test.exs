defmodule Fermix.CLI.SettingsCommand.ArgsTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.SettingsCommand.Args

  @off %{json: false, stdin: false, info: false}
  @json %{@off | json: true}

  describe "parse/1" do
    test "no arguments and a bare list both list the sections" do
      assert Args.parse([]) == {:list, @off}
      assert Args.parse(["list"]) == {:list, @off}
    end

    test "--json is read before or after the positionals" do
      assert Args.parse(["--json"]) == {:list, @json}
      assert Args.parse(["--json", "show", "memory"]) == {:show, "memory", @json}
      assert Args.parse(["show", "memory", "--json"]) == {:show, "memory", @json}
    end

    test "every grammar form parses to its command" do
      assert Args.parse(["show", "memory", "--info"]) ==
               {:show, "memory", %{@off | info: true}}

      assert Args.parse(["set", "memory", "a=1", "b=x"]) ==
               {:set, "memory", [{"a", "1"}, {"b", "x"}], @off}

      assert Args.parse(["secret", "set", "tavily_api_key"]) ==
               {:secret_set, "tavily_api_key", @off}

      assert Args.parse(["secret", "set", "tavily_api_key", "--stdin", "--json"]) ==
               {:secret_set, "tavily_api_key", %{@json | stdin: true}}

      assert Args.parse(["secret", "clear", "brave_api_key"]) ==
               {:secret_clear, "brave_api_key", @off}

      assert Args.parse(["primary"]) == {:primary, nil, @off}
      assert Args.parse(["primary", "openai"]) == {:primary, "openai", @off}
      assert Args.parse(["reload", "--json"]) == {:reload, @json}
    end

    test "an unknown switch is a usage error" do
      assert {:usage, _reason} = Args.parse(["list", "--bogus"])
      assert {:usage, _reason} = Args.parse(["show", "memory", "-x"])
    end

    test "--stdin is accepted only by secret set and --info only by show" do
      assert {:usage, _reason} = Args.parse(["list", "--stdin"])
      assert {:usage, _reason} = Args.parse(["secret", "clear", "brave_api_key", "--stdin"])
      assert {:usage, _reason} = Args.parse(["set", "memory", "a=1", "--info"])
      assert {:usage, _reason} = Args.parse(["secret", "set", "brave_api_key", "--info"])
    end

    test "unknown subcommands, missing operands and extra operands are usage errors" do
      for argv <- [
            ["frobnicate"],
            ["show"],
            ["show", "memory", "extra"],
            ["set", "memory"],
            ["secret"],
            ["secret", "set"],
            ["secret", "clear"],
            ["secret", "clear", "a", "b"],
            ["primary", "openai", "extra"],
            ["reload", "now"],
            ["list", "extra"],
            ["show", ""],
            ["secret", "set", ""],
            ["primary", ""]
          ] do
        assert {:usage, reason} = Args.parse(argv), "expected usage for #{inspect(argv)}"
        assert is_binary(reason)
      end
    end

    test "a value typed after a secret id is refused as a secret in argv" do
      assert Args.parse(["secret", "set", "openai_api_key", "sk-test-abc123"]) ==
               {:secret_in_argv, :secret_set, "openai_api_key"}

      assert Args.parse(["secret", "set", "openai_api_key", "sk-test-abc123", "--stdin"]) ==
               {:secret_in_argv, :secret_set, "openai_api_key"}
    end

    # The secret-id families are this build's own published constants, so the
    # refusal needs no daemon and holds on a home with no daemon at all.
    test "a set naming a published secret id is refused before any daemon call" do
      for key <- [
            "openai_api_key",
            "env:ACME_TOKEN",
            "plugin:acme",
            "oauth_client:github",
            "anthropic_setup_token"
          ] do
        assert Args.parse(["set", "providers.openai", "#{key}=sk-test-abc123"]) ==
                 {:secret_in_argv, :set, key}
      end
    end

    test "a secret key typed with its value as a separate argument is still refused" do
      assert Args.parse(["set", "providers.openai", "openai_api_key", "sk-test-abc123"]) ==
               {:secret_in_argv, :set, "openai_api_key"}
    end

    test "the usage reason never echoes a token that may be a secret" do
      assert {:usage, reason} = Args.parse(["set", "memory", "sk-test-abc123"])
      refute reason =~ "sk-test-abc123"
    end

    # `ID=VALUE` is the form `set` teaches, and a value starting with `--` is
    # parsed as an unknown switch: both are a secret on the command line.
    test "a value glued to a secret id, or typed as a switch, is refused as a secret in argv" do
      for argv <- [
            ["secret", "set", "openai_api_key=sk-test-abc123"],
            ["secret", "set", "openai_api_key=sk-test-abc123", "--stdin"],
            ["secret", "clear", "openai_api_key=sk-test-abc123"],
            ["secret", "set", "openai_api_key", "--sk-test-abc123"]
          ] do
        assert Args.parse(argv) == {:secret_in_argv, :secret_set, "openai_api_key"},
               "expected a refusal for #{inspect(argv)}"
      end

      assert Args.parse(["secret", "set", "env:ACME_TOKEN=abc"]) ==
               {:secret_in_argv, :secret_set, "env:ACME_TOKEN"}
    end

    test "an unknown switch is never echoed, because it may be a secret" do
      assert {:usage, reason} = Args.parse(["list", "--sk-test-abc123"])
      refute reason =~ "sk-test-abc123"
    end
  end

  describe "pairs/1" do
    test "splits on the first equals sign only" do
      assert Args.pairs(["a=b=c"]) == {:ok, [{"a", "b=c"}]}
    end

    test "an empty value is kept as the empty string" do
      assert Args.pairs(["a="]) == {:ok, [{"a", ""}]}
    end

    test "a token with no equals sign, an empty key or a repeated key is a usage error" do
      assert {:usage, _reason} = Args.pairs(["novalue"])
      assert {:usage, _reason} = Args.pairs(["=x"])
      assert {:usage, reason} = Args.pairs(["a=1", "a=2"])
      assert reason =~ "a"
    end

    test "keeps the order the operator typed" do
      assert Args.pairs(["b=2", "a=1"]) == {:ok, [{"b", "2"}, {"a", "1"}]}
    end
  end

  describe "coerce/2" do
    test "a toggle takes exactly true or false" do
      assert Args.coerce("toggle", "true") == true
      assert Args.coerce("toggle", "false") == false
      assert Args.coerce("toggle", "yes") == "yes"
    end

    test "a number takes a whole integer or float literal" do
      assert Args.coerce("number", "12") === 12
      assert Args.coerce("number", "0.75") === 0.75
      assert Args.coerce("number", "-3") === -3
      assert Args.coerce("number", "12abc") == "12abc"
      assert Args.coerce("number", "lots") == "lots"
    end

    test "a list is comma separated and sent unmodified for the daemon to trim" do
      assert Args.coerce("list", "") == []
      assert Args.coerce("list", "a,b") == ["a", "b"]
      assert Args.coerce("list", " a , b") == [" a ", " b"]
    end

    test "text, choice and any kind this build does not know pass raw" do
      assert Args.coerce("text", "12") == "12"
      assert Args.coerce("choice", "true") == "true"
      assert Args.coerce("future_kind", "0.5") == "0.5"
      assert Args.coerce(nil, "x") == "x"
    end
  end

  describe "secret_keys/2 and values/2" do
    @rows [
      %{"key" => "future_token", "kind" => "secret"},
      %{"key" => "compaction_threshold", "kind" => "number"},
      %{"key" => "enabled", "kind" => "toggle"}
    ]

    test "a row whose kind is secret is a secret even when no family names it" do
      assert Args.secret_keys([{"enabled", "true"}, {"future_token", "x"}], @rows) ==
               ["future_token"]
    end

    test "no secret keys among ordinary rows" do
      assert Args.secret_keys([{"compaction_threshold", "0.5"}], @rows) == []
    end

    test "values are coerced by the row kind and a key with no row passes raw" do
      assert Args.values(
               [{"compaction_threshold", "0.75"}, {"enabled", "false"}, {"nope", "12"}],
               @rows
             ) == %{"compaction_threshold" => 0.75, "enabled" => false, "nope" => "12"}
    end
  end
end
