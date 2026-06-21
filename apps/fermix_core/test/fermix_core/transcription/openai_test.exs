defmodule FermixCore.Transcription.OpenAITest do
  # async: false — exercises the real Whisper Req pipeline through an adapter seam.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription.OpenAI

  describe "transcribe/2 timeout wiring" do
    test "carries the transcription policy timeout into the Whisper request" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-timeout")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()

        adapter = fn req ->
          send(test_pid, {:transcribe_receive_timeout, req.options[:receive_timeout]})
          {req, %Req.TransportError{reason: :timeout}}
        end

        {:error, _reason} =
          OpenAI.transcribe(path,
            auth_mode: :api_key,
            api_key: "sk-test",
            req_options: [adapter: adapter]
          )

        # A multi-minute voice note must not be capped at Req's silent 15s default.
        assert_received {:transcribe_receive_timeout, 120_000}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end

    test "an explicit req_options receive_timeout still overrides the policy" do
      tmp_dir = FermixTestSupport.SafeRm.make_tmp_dir!("transcription-timeout-override")

      try do
        path = Path.join(tmp_dir, "clip.ogg")
        File.write!(path, "OGGDATA")
        test_pid = self()

        adapter = fn req ->
          send(test_pid, {:transcribe_receive_timeout, req.options[:receive_timeout]})
          {req, %Req.TransportError{reason: :timeout}}
        end

        {:error, _reason} =
          OpenAI.transcribe(path,
            auth_mode: :api_key,
            api_key: "sk-test",
            req_options: [adapter: adapter, receive_timeout: 5_000]
          )

        assert_received {:transcribe_receive_timeout, 5_000}
      after
        FermixTestSupport.SafeRm.rm_rf!(tmp_dir)
      end
    end
  end
end
