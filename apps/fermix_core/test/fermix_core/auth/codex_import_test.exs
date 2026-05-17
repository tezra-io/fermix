defmodule FermixCore.Auth.CodexImportTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.CodexImport

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
