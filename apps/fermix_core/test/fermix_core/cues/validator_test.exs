defmodule FermixCore.Cues.ValidatorTest do
  @moduledoc """
  The owner's validator (M60 §10.2, C11): one line of JSON in, the last line of
  output decides; anything else, a crash or a timeout is a refusal.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Validator
  alias FermixTestSupport.SafeRm

  @request %{
    "mandate" => "release-issues",
    "tool" => "github_create_issue",
    "args" => %{"owner" => "example-org", "repo" => "ops"},
    "job" => "release_watch_4b1e",
    "run_id" => "run_1",
    "idempotency_key" => "0123456789abcdef0123456789abcdef",
    "calls_this_run" => 0,
    "cue" => %{"source" => "eng-blogs", "item_id" => "item-1"}
  }

  defp script!(body) do
    dir = SafeRm.make_tmp_dir!("validator")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    path = Path.join(dir, "validate.sh")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp mandate(validator, extra \\ %{}) do
    Map.merge(
      %{name: "release-issues", validator: validator, interpreter: nil, validator_env: []},
      extra
    )
  end

  defp no_env, do: [env_resolver: fn [] -> {:ok, []} end]

  test "a validator that allows; one that refuses with its reason" do
    allow = script!(~s(cat > /dev/null; echo '{"allow": true}'\n))
    assert :allow = Validator.run(mandate(allow), @request, no_env())

    refuse =
      script!(~s(cat > /dev/null; echo '{"allow": false, "reason": "only the ops repo"}'\n))

    assert {:refuse, "only the ops repo"} = Validator.run(mandate(refuse), @request, no_env())
  end

  test "the request is one line of JSON on stdin, then end of file" do
    path =
      script!("""
      line=$(cat)
      case "$line" in
        *'"repo":"ops"'*) echo '{"allow": true}' ;;
        *) echo '{"allow": false, "reason": "no"}' ;;
      esac
      """)

    assert :allow = Validator.run(mandate(path), @request, no_env())

    web = put_in(@request, ["args", "repo"], "web")
    assert {:refuse, "no"} = Validator.run(mandate(path), web, no_env())
  end

  test "warnings before the answer are logged, never parsed; the last line decides" do
    path =
      script!(
        ~s(cat > /dev/null; echo '{"allow": false}'; echo "warning: slow" 1>&2; echo '{"allow": true}'\n)
      )

    assert :allow = Validator.run(mandate(path), @request, no_env())
  end

  test "standard error is no part of the answer: a warning after it changes nothing" do
    path =
      script!(~s(cat > /dev/null; echo '{"allow": true}'; echo "warning: slow" 1>&2\n))

    assert :allow = Validator.run(mandate(path), @request, no_env())

    test_pid = self()

    runner = fn _exe, _args, opts ->
      send(test_pid, {:runner_opts, opts})
      {:ok, %{exit: 0, stdout: ~s({"allow": true}\n), truncated?: false}}
    end

    assert :allow = Validator.run(mandate(path), @request, no_env() ++ [command_runner: runner])
    assert_received {:runner_opts, opts}
    assert opts[:stderr] == :discard
  end

  test "nonsense, no answer, a crash and a timeout are refusals" do
    assert {:refuse, "the validator's answer was not understood"} =
             Validator.run(mandate(script!("echo allow\n")), @request, no_env())

    assert {:refuse, "the validator printed no answer"} =
             Validator.run(mandate(script!("true\n")), @request, no_env())

    assert {:refuse, "the validator stopped with exit status 3"} =
             Validator.run(
               mandate(script!(~s(echo '{"allow": true}'; exit 3\n))),
               @request,
               no_env()
             )

    timeout = [command_runner: fn _exe, _args, _opts -> {:error, {:timeout, 5_000}} end]

    assert {:refuse, "the validator did not answer within 5 seconds"} =
             Validator.run(mandate("/usr/local/libexec/v"), @request, no_env() ++ timeout)
  end

  test "the program runs with a replaced environment: PATH, LANG and validator_env only" do
    name = "FERMIX_VALIDATOR_PARENT_ONLY_#{System.unique_integer([:positive])}"
    System.put_env(name, "inherited")
    on_exit(fn -> System.delete_env(name) end)

    path =
      script!("""
      cat > /dev/null
      names=$(env | cut -d= -f1 | sort | tr '\\n' ' ')
      printf '{"allow": false, "reason": "%s|%s|%s"}\\n' "$PATH" "$ALPACA_KEY" "$names"
      """)

    resolver = [env_resolver: fn ["ALPACA_KEY"] -> {:ok, [{"ALPACA_KEY", "key-1"}]} end]

    assert {:refuse, reason} =
             Validator.run(mandate(path, %{validator_env: ["ALPACA_KEY"]}), @request, resolver)

    [path_value, key, names] = String.split(reason, "|")
    assert path_value == "/usr/bin:/bin"
    assert key == "key-1"
    assert "ALPACA_KEY" in String.split(names)
    refute name in String.split(names)
  end

  test "a validator_env name the daemon cannot read refuses the call" do
    absent = "FERMIX_VALIDATOR_ABSENT_#{System.unique_integer([:positive])}"
    path = script!(~s(echo '{"allow": true}'\n))

    assert {:refuse, reason} = Validator.run(mandate(path, %{validator_env: [absent]}), @request)
    assert reason =~ absent
  end

  test "with an interpreter, the program is <interpreter> -I <validator>" do
    interpreter =
      script!(~s(cat > /dev/null; printf '{"allow": false, "reason": "%s %s"}\\n' "$1" "$2"\n))

    assert {:refuse, "-I /opt/validators/v.py"} =
             Validator.run(
               mandate("/opt/validators/v.py", %{interpreter: interpreter}),
               @request,
               no_env()
             )
  end
end
