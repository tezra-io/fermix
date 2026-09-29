defmodule FermixCore.Auth.CodexImportTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.CodexImport
  alias FermixCore.Auth.Store

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "fermix_codex_import_#{System.unique_integer([:positive])}")
  end

  defp write_codex(dir, refresh_token) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "codex_auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        "auth_mode" => "chatgpt",
        "tokens" => %{"access_token" => "codex_at", "refresh_token" => refresh_token}
      })
    )

    path
  end

  def success_plug(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "access_token" => "fresh_at",
        "refresh_token" => "fresh_rt",
        "expires_in" => 3600
      })
    )
  end

  def failure_plug(conn) do
    Plug.Conn.send_resp(conn, 500, "boom")
  end

  describe "import_tokens/1" do
    test "refreshes against codex refresh_token and persists to fermix store" do
      dir = tmp_dir()
      codex_path = write_codex(dir, "codex_rt")
      fermix_path = Path.join(dir, "fermix_auth.json")

      assert {:ok, entry} =
               CodexImport.import_tokens(
                 codex_path: codex_path,
                 fermix_path: fermix_path,
                 req_options: [plug: &__MODULE__.success_plug/1]
               )

      assert entry.tokens.access_token == "fresh_at"
      assert entry.tokens.refresh_token == "fresh_rt"
      assert File.exists?(fermix_path)

      {:ok, raw} = File.read(fermix_path)
      data = Jason.decode!(raw)
      assert data["providers"]["openai_codex"]["tokens"]["access_token"] == "fresh_at"

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    # The import is a sign-in: it holds the Codex profile lock from before its
    # refresh to its write, so it cannot land inside Fermix's own refresh of
    # that profile and be overwritten by it. A refresh that ends within the
    # wait is waited out.
    test "waits while a refresh of the Codex profile holds its lock" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("codex-import-lock")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      codex_path = write_codex(dir, "codex_rt")
      fermix_path = Path.join(dir, "fermix_auth.json")
      lock = Store.profile_lock_path(:openai_codex, fermix_path)
      File.write!(lock, "0 a-refresh\n")

      importer =
        Task.async(fn ->
          CodexImport.import_tokens(
            codex_path: codex_path,
            fermix_path: fermix_path,
            req_options: [plug: &__MODULE__.success_plug/1]
          )
        end)

      assert Task.yield(importer, 300) == nil

      FermixTestSupport.SafeRm.rm!(lock)
      assert {:ok, _entry} = Task.await(importer)

      assert {:ok, %{tokens: %{access_token: "fresh_at"}}} =
               Store.read(:openai_codex, fermix_path)
    end

    # The import's refresh spends the Codex CLI's refresh token. A profile that
    # stays busy past the lock's wait refuses before that, so a failed import
    # leaves the Codex CLI signed in; it used to refresh first and then wait
    # out a stale lock the app's job budget could not outlast.
    test "refuses a busy Codex profile before it spends the Codex CLI's refresh token" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("codex-import-busy")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      codex_path = write_codex(dir, "codex_rt")
      fermix_path = Path.join(dir, "fermix_auth.json")
      File.write!(Store.profile_lock_path(:openai_codex, fermix_path), "0 a-refresh\n")
      parent = self()

      token_endpoint = fn conn ->
        send(parent, :token_endpoint_called)
        success_plug(conn)
      end

      importer =
        Task.async(fn ->
          CodexImport.import_tokens(
            codex_path: codex_path,
            fermix_path: fermix_path,
            req_options: [plug: token_endpoint]
          )
        end)

      assert {:ok, {:error, :profile_busy}} =
               Task.yield(importer, 15_000) || Task.shutdown(importer, :brutal_kill)

      refute_received :token_endpoint_called
      refute File.exists?(fermix_path)
    end

    test "returns error and does not persist when refresh fails" do
      dir = tmp_dir()
      codex_path = write_codex(dir, "codex_rt")
      fermix_path = Path.join(dir, "fermix_auth.json")

      assert {:error, _reason} =
               CodexImport.import_tokens(
                 codex_path: codex_path,
                 fermix_path: fermix_path,
                 req_options: [plug: &__MODULE__.failure_plug/1]
               )

      refute File.exists?(fermix_path)

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "returns no_codex_auth when codex file is missing" do
      dir = tmp_dir()
      File.mkdir_p!(dir)

      assert {:error, :no_codex_auth} =
               CodexImport.import_tokens(
                 codex_path: Path.join(dir, "missing.json"),
                 fermix_path: Path.join(dir, "fermix.json"),
                 req_options: [plug: &__MODULE__.success_plug/1]
               )

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "returns codex_auth_missing_refresh_token when refresh_token is empty" do
      dir = tmp_dir()
      codex_path = write_codex(dir, "")
      fermix_path = Path.join(dir, "fermix_auth.json")

      assert {:error, :codex_auth_missing_refresh_token} =
               CodexImport.import_tokens(
                 codex_path: codex_path,
                 fermix_path: fermix_path,
                 req_options: [plug: &__MODULE__.success_plug/1]
               )

      FermixTestSupport.SafeRm.rm_rf!(dir)
    end
  end

  describe "codex_available?/1" do
    test "true when codex file has a refresh_token" do
      dir = tmp_dir()
      path = write_codex(dir, "rt")
      assert CodexImport.codex_available?(path)
      FermixTestSupport.SafeRm.rm_rf!(dir)
    end

    test "false when codex file is missing" do
      refute CodexImport.codex_available?(Path.join(tmp_dir(), "no.json"))
    end
  end
end
