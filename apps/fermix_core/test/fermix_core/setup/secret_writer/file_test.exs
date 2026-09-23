defmodule FermixCore.Setup.SecretWriter.FileTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.SecretWriter.File, as: FileStore

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("secret-file-store")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)
    %{home: home, opts: [impl: FileStore, home: home]}
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  test "a secret round-trips through a 0600 file in a 0700 directory", %{home: home, opts: opts} do
    assert :ok = SecretWriter.put(:telegram_bot_token, "123:abc", opts)
    assert {:ok, "123:abc"} = SecretWriter.get(:telegram_bot_token, opts)

    directory = Path.join(home, "secrets")
    assert mode(directory) == 0o700
    assert mode(Path.join(directory, "TELEGRAM_BOT_TOKEN")) == 0o600
    assert FileStore.stored(home: home) == ["TELEGRAM_BOT_TOKEN"]
  end

  test "a value with newlines and non-ASCII comes back byte for byte", %{opts: opts} do
    value = "line one\nline two\n  spaced ☕\n"
    assert :ok = SecretWriter.put(:openai_api_key, value, opts)
    assert {:ok, ^value} = SecretWriter.get(:openai_api_key, opts)
  end

  test "a rewrite replaces the value and leaves no staging file behind", %{home: home, opts: opts} do
    :ok = SecretWriter.put(:openai_api_key, "first", opts)
    :ok = SecretWriter.put(:openai_api_key, "second", opts)

    assert {:ok, "second"} = SecretWriter.get(:openai_api_key, opts)
    assert File.ls!(Path.join(home, "secrets")) == ["OPENAI_API_KEY"]
  end

  test "a missing secret is missing, and deleting it is fine", %{opts: opts} do
    assert {:error, :missing_secret} = SecretWriter.get(:openai_api_key, opts)
    assert :ok = SecretWriter.delete(:openai_api_key, opts)

    :ok = SecretWriter.put(:openai_api_key, "gone soon", opts)
    assert :ok = SecretWriter.delete(:openai_api_key, opts)
    assert {:error, :missing_secret} = SecretWriter.get(:openai_api_key, opts)
  end

  test "a file another account can read is refused, by path", %{home: home, opts: opts} do
    :ok = SecretWriter.put(:openai_api_key, "leaked", opts)
    path = Path.join([home, "secrets", "OPENAI_API_KEY"])
    File.chmod!(path, 0o644)

    assert {:error, {:file_store, {:readable_by_others, ^path}}} =
             SecretWriter.get(:openai_api_key, opts)

    assert SecretWriter.format_error(:openai_api_key, {:file_store, {:readable_by_others, path}}) =~
             "chmod 600 #{path}"
  end

  test "a skill's own credential keeps its family in the file name", %{home: home, opts: opts} do
    key = {:external_env, "ALPACA_API_KEY"}
    assert :ok = SecretWriter.put(key, "pk-live", opts)
    assert {:ok, "pk-live"} = SecretWriter.get(key, opts)
    assert File.exists?(Path.join([home, "secrets", "external_env.ALPACA_API_KEY"]))

    source = SecretWriter.command_source(key, opts)
    assert %{source: :command, args: [path]} = source
    assert path == Path.join([home, "secrets", "external_env.ALPACA_API_KEY"])
    assert String.ends_with?(source.command, "cat")
  end

  test "the probe is available on a home that exists, and says where the files live", %{
    home: home,
    opts: opts
  } do
    assert %{store: :file, state: :available, sentence: sentence} = SecretWriter.probe(opts)
    assert sentence =~ Path.join(home, "secrets")
    assert SecretWriter.usable?(SecretWriter.probe(opts))
  end

  test "the probe refuses a home that does not exist, or a secrets path that is a file", %{
    home: home
  } do
    missing = Path.join(home, "nowhere")
    assert %{state: :unavailable} = SecretWriter.probe(impl: FileStore, home: missing)

    File.write!(Path.join(home, "secrets"), "not a directory")

    assert %{state: :unavailable, sentence: sentence} =
             SecretWriter.probe(impl: FileStore, home: home)

    assert sentence =~ "is not a directory"
  end
end
