defmodule FermixCore.Transcription.StreamSessionTest do
  # async: false — the configured-backend test reads global `:transcription` app
  # env, so it establishes its own baseline and restores it on exit.
  use ExUnit.Case, async: false

  alias FermixCore.Transcription
  alias FermixCore.Transcription.ChunkedStream
  alias FermixCore.Transcription.StreamSession

  # Declares streaming, so `open_stream/2` must hand the call straight to it.
  defmodule NativeBackend do
    @behaviour FermixCore.Transcription.Backend

    @impl true
    def name, do: :native_fake

    @impl true
    def capabilities, do: %{streaming?: true, local?: false}

    @impl true
    def configured?(_opts), do: :ok

    @impl true
    def transcribe(_path, _opts), do: {:error, :batch_not_used}

    @impl true
    def open_stream(consumer, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:native_open_stream, consumer, opts})
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end
  end

  # Declares batch only, so `open_stream/2` must wrap it in the chunked adapter.
  defmodule BatchBackend do
    @behaviour FermixCore.Transcription.Backend

    @impl true
    def name, do: :batch_fake

    @impl true
    def capabilities, do: %{streaming?: false, local?: false}

    @impl true
    def configured?(_opts), do: :ok

    @impl true
    def transcribe(_path, _opts), do: {:ok, "text"}
  end

  # A backend the operator has not finished configuring.
  defmodule UnconfiguredBackend do
    @behaviour FermixCore.Transcription.Backend

    @impl true
    def name, do: :unconfigured_fake

    @impl true
    def capabilities, do: %{streaming?: true, local?: false}

    @impl true
    def configured?(_opts), do: {:error, :not_configured}

    @impl true
    def transcribe(_path, _opts), do: {:error, :not_configured}

    @impl true
    def open_stream(_consumer, opts) do
      send(Keyword.fetch!(opts, :test_pid), :unconfigured_open_stream)
      {:ok, self()}
    end
  end

  # The minimal session the facade's casts and call must reach.
  defmodule EchoSession do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_cast(message, test_pid) do
      send(test_pid, {:cast, message})
      {:noreply, test_pid}
    end

    @impl true
    def handle_call(:stop, _from, test_pid) do
      send(test_pid, {:call, :stop})
      {:reply, :ok, test_pid}
    end
  end

  setup do
    prior = Application.get_env(:fermix_core, :transcription)
    on_exit(fn -> restore(prior) end)
    :ok
  end

  describe "open_stream/2 dispatch" do
    test "a streaming backend opens its own native session" do
      assert {:ok, session} =
               Transcription.open_stream(self(), backend: NativeBackend, test_pid: self())

      assert is_pid(session)
      assert_receive {:native_open_stream, consumer, opts}
      assert consumer == self()
      # Opts ride through unchanged so caller correlation reaches the spans.
      assert opts[:test_pid] == self()

      Process.exit(session, :kill)
    end

    test "a batch-only backend is wrapped in the chunked adapter" do
      assert {:ok, session} = Transcription.open_stream(self(), backend: BatchBackend)

      assert {:dictionary, dictionary} = Process.info(session, :dictionary)
      assert dictionary[:"$initial_call"] == {ChunkedStream, :init, 1}

      assert :ok = StreamSession.stop(session)
    end

    test "an unconfigured backend refuses synchronously, starting nothing" do
      assert {:error, :not_configured} =
               Transcription.open_stream(self(), backend: UnconfiguredBackend, test_pid: self())

      refute_received :unconfigured_open_stream
    end

    test "an unknown configured backend fails loud before any session exists" do
      Application.put_env(:fermix_core, :transcription, backend: "nope")

      assert {:error, message} = Transcription.open_stream(self())
      assert message =~ "Unknown transcription backend"
    end
  end

  describe "facade" do
    test "push_pcm/2 and finish/1 cast, stop/1 calls" do
      {:ok, session} = EchoSession.start_link(self())

      assert :ok = StreamSession.push_pcm(session, <<0, 0>>)
      assert_receive {:cast, {:push_pcm, <<0, 0>>}}

      assert :ok = StreamSession.finish(session)
      assert_receive {:cast, :finish}

      assert :ok = StreamSession.stop(session)
      assert_receive {:call, :stop}
    end

    test "guards reject a non-pid session or non-binary audio" do
      assert_raise FunctionClauseError, fn -> StreamSession.push_pcm(:not_a_pid, <<>>) end
      assert_raise FunctionClauseError, fn -> StreamSession.push_pcm(self(), :not_binary) end
      assert_raise FunctionClauseError, fn -> StreamSession.finish(:not_a_pid) end
    end
  end

  defp restore(nil), do: Application.delete_env(:fermix_core, :transcription)
  defp restore(value), do: Application.put_env(:fermix_core, :transcription, value)
end
