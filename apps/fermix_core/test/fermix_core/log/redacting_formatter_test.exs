defmodule FermixCore.Log.RedactingFormatterTest do
  use ExUnit.Case, async: true

  alias FermixCore.Log.RedactingFormatter

  @fake_openai "sk-proj-" <> String.duplicate("Ab1", 20)
  @fake_github "ghp_" <> String.duplicate("Cd2", 10)
  @fake_github_pat "github_pat_" <> String.duplicate("Ef3", 10)
  @fake_slack "xoxb-1234567890-abcDEF123ghi"
  @fake_aws "AKIA" <> String.duplicate("A7", 8)
  @fake_bearer "Bearer " <> String.duplicate("Tk9", 10)
  @fake_telegram "123456789:" <> String.duplicate("Gh4", 12)
  @fake_xai "xai-" <> String.duplicate("Jk5", 10)
  @fake_google "AIza" <> String.duplicate("Mn6", 12)

  describe "redact/1" do
    test "redacts every supported secret shape" do
      for {token, label} <- [
            {@fake_openai, "openai"},
            {@fake_github, "github"},
            {@fake_github_pat, "github"},
            {@fake_slack, "slack"},
            {@fake_aws, "aws"},
            {@fake_bearer, "bearer"},
            {@fake_telegram, "telegram"},
            {@fake_xai, "xai"},
            {@fake_google, "google"}
          ] do
        redacted = RedactingFormatter.redact("before #{token} after")

        refute redacted =~ token, "#{label} token survived redaction"
        assert redacted =~ "[REDACTED:#{label}]"
        assert redacted =~ "before "
        assert redacted =~ " after"
      end
    end

    test "redacts multiple secrets in one line" do
      line = "a=#{@fake_openai} b=#{@fake_telegram}"
      redacted = RedactingFormatter.redact(line)

      refute redacted =~ @fake_openai
      refute redacted =~ @fake_telegram
      assert redacted =~ "[REDACTED:openai]"
      assert redacted =~ "[REDACTED:telegram]"
    end

    test "leaves ordinary log lines untouched" do
      for line <- [
            "12:30:01.123 [info] GET /setup 200 in 3ms",
            "risk-based-authentication-flow enabled for task-management-toolkit",
            "commit 41249c0f built at 2026-07-05 12:00:00",
            "Bearer of bad news",
            "sk-short"
          ] do
        assert RedactingFormatter.redact(line) == line
      end
    end
  end

  describe "format/2 wrapping :logger_formatter" do
    test "redacts a plain string message" do
      event = %{
        level: :error,
        msg: {:string, "resolved secret #{@fake_openai} from keychain"},
        meta: %{time: 0}
      }

      formatted = format_with_wrapped(event)

      refute formatted =~ @fake_openai
      assert formatted =~ "[REDACTED:openai]"
    end

    test "preserves non-ASCII codepoints the inner formatter emits as chardata" do
      # :logger_formatter emits chardata where µ (in LiveView's "Replied in
      # 89µs") is the bare codepoint integer 181 inside a charlist. Treating
      # that as a byte produces invalid UTF-8 and the handler drops the line.
      event = %{
        level: :debug,
        msg: {:string, ["Replied in 89", [181], "s"]},
        meta: %{time: 0}
      }

      formatted = format_with_wrapped(event)

      assert String.valid?(formatted)
      assert formatted =~ "Replied in 89µs"
    end

    test "redacts a crash-report-shaped event" do
      event = %{
        level: :error,
        msg:
          {:report,
           %{
             label: {:gen_server, :terminate},
             report: %{
               last_message: {:port_data, @fake_openai},
               state: %{secret: @fake_telegram}
             }
           }},
        meta: %{time: 0}
      }

      formatted = format_with_wrapped(event)

      refute formatted =~ @fake_openai
      refute formatted =~ @fake_telegram
      assert formatted =~ "[REDACTED:openai]"
    end
  end

  describe "install/1" do
    @tag :tmp_dir
    test "file handler emits redacted output end to end", %{tmp_dir: tmp_dir} do
      handler_id = :"redact_test_#{System.unique_integer([:positive])}"
      log_file = Path.join(tmp_dir, "redact_test.log")

      :ok =
        :logger.add_handler(handler_id, :logger_std_h, %{
          config: %{file: String.to_charlist(log_file)},
          formatter:
            RedactingFormatter.wrap(
              {:logger_formatter, %{template: [:time, ~c" ", :level, ~c" ", :msg, ~c"\n"]}}
            )
        })

      on_exit(fn -> :logger.remove_handler(handler_id) end)

      require Logger
      Logger.error("leaked #{@fake_openai} in test")
      :ok = :logger_std_h.filesync(handler_id)

      contents = File.read!(log_file)
      assert contents =~ "[REDACTED:openai]"
      refute contents =~ @fake_openai
    end

    test "returns an error for a missing handler" do
      assert {:error, _} = RedactingFormatter.install(:no_such_handler)
    end
  end

  defp format_with_wrapped(event) do
    {mod, cfg} = RedactingFormatter.wrap({:logger_formatter, %{template: [:msg, ~c"\n"]}})

    event
    |> mod.format(cfg)
    |> IO.iodata_to_binary()
  end
end
