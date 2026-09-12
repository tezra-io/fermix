defmodule FermixCore.Auth.ClientRejectionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.ClientRejection
  alias FermixCore.Auth.OAuthProvider
  alias FermixCore.Auth.OAuthProviders

  @client [client_id: "client-id", client_secret: "stale-secret", scopes: []]

  defp provider(id) do
    {:ok, provider} = OAuthProviders.definition(id, @client)
    provider
  end

  defp refusal(error), do: %{"error" => error}
  defp refusal(error, description), do: %{"error" => error, "error_description" => description}

  describe "classify/3 — the refusals each provider declares" do
    # Verified live 2026-09-10/11: X answers a present-but-rejected Basic client
    # credential this way, which reads like a request Fermix built wrong.
    test "X 401 unauthorized_client is the saved client refused" do
      body = refusal("unauthorized_client", "Missing valid authorization header")

      assert {:oauth_client_rejected, detail} = ClientRejection.classify(provider("x"), 401, body)

      assert detail == %{
               provider: "x",
               provider_name: "X",
               status: 401,
               error: "unauthorized_client",
               description: "Missing valid authorization header"
             }
    end

    test "Google 401 invalid_client is the saved client refused" do
      body = refusal("invalid_client", "Unauthorized")

      assert {:oauth_client_rejected, detail} =
               ClientRejection.classify(provider("google"), 401, body)

      assert detail.provider == "google"
      assert detail.provider_name == "Google"
      assert detail.error == "invalid_client"
    end

    # GitHub and Slack answer the refusal with a success status, so the status
    # is recorded but never decides.
    test "GitHub 200 incorrect_client_credentials is the saved client refused" do
      body =
        refusal(
          "incorrect_client_credentials",
          "The client_id and/or client_secret passed are incorrect."
        )

      assert {:oauth_client_rejected, detail} =
               ClientRejection.classify(provider("github"), 200, body)

      assert detail.status == 200
      assert detail.provider_name == "GitHub"
      assert detail.description == "The client_id and/or client_secret passed are incorrect."
    end

    test "Slack 200 bad_client_secret and invalid_client_id are the saved client refused" do
      for error <- ["bad_client_secret", "invalid_client_id"] do
        body = %{"ok" => false, "error" => error}

        assert {:oauth_client_rejected, detail} =
                 ClientRejection.classify(provider("slack"), 200, body)

        assert detail.error == error
        assert detail.provider_name == "Slack"
        assert detail.description == nil
      end
    end

    test "Notion 401 invalid_client is the saved client refused" do
      assert {:oauth_client_rejected, %{provider_name: "Notion"}} =
               ClientRejection.classify(provider("notion"), 401, refusal("invalid_client"))
    end

    test "every plugin provider declares at least one refusal" do
      for id <- OAuthProviders.providers() do
        assert provider(id).client_rejection_errors != [], "#{id} declares no refusal code"
      end
    end
  end

  describe "classify/3 — what is not a refused client" do
    test "invalid_grant is a dead grant, not a refused client" do
      assert ClientRejection.classify(provider("x"), 400, refusal("invalid_grant")) == nil
      assert ClientRejection.classify(provider("google"), 400, refusal("invalid_grant")) == nil
    end

    # Google answers unauthorized_client when a refresh token was minted for a
    # different client: signing in again is the fix, not the secret.
    test "Google unauthorized_client is not a refused client" do
      assert ClientRejection.classify(provider("google"), 400, refusal("unauthorized_client")) ==
               nil
    end

    test "a built-in provider declares no refusal, so nothing it answers is one" do
      for builtin <- [OAuthProvider.anthropic(), OAuthProvider.xai()] do
        assert builtin.client_rejection_errors == []
        assert ClientRejection.classify(builtin, 401, refusal("invalid_client")) == nil
        assert ClientRejection.classify(builtin, 401, refusal("unauthorized_client")) == nil
      end
    end

    test "a body that is not a decoded map is not classified" do
      raw = ~s({"error":"unauthorized_client"})

      assert ClientRejection.classify(provider("x"), 401, raw) == nil
      assert ClientRejection.classify(provider("x"), 401, %{"message" => "no"}) == nil
      assert ClientRejection.classify(provider("x"), 401, %{"error" => %{"code" => 1}}) == nil
    end
  end

  describe "the vendor's description" do
    test "is redacted and bounded before it is kept" do
      long = "Bearer abc.def.ghi rejected " <> String.duplicate("x", 500)
      body = refusal("unauthorized_client", long)

      assert {:oauth_client_rejected, detail} = ClientRejection.classify(provider("x"), 401, body)

      refute detail.description =~ "abc.def.ghi"
      assert String.length(detail.description) <= 200
    end

    test "a description that is not text is dropped" do
      body = %{"error" => "unauthorized_client", "error_description" => %{"nested" => true}}

      assert {:oauth_client_rejected, %{description: nil}} =
               ClientRejection.classify(provider("x"), 401, body)
    end
  end

  describe "the words" do
    setup do
      body = refusal("unauthorized_client", "Missing valid authorization header")
      {:oauth_client_rejected, detail} = ClientRejection.classify(provider("x"), 401, body)
      %{detail: detail}
    end

    test "the refusal sentence names the provider and the one fix", %{detail: detail} do
      assert ClientRejection.sentence(detail) ==
               "X refused the sign-in client saved in Fermix. Copy the client ID and secret " <>
                 "from the X developer console into the X sign-in client in Fermix setup, " <>
                 "then sign in again."
    end

    test "the grant sentence says the sign-in could not renew" do
      assert ClientRejection.grant_sentence("x") ==
               "X refused the saved sign-in client, so the sign-in could not renew."

      assert ClientRejection.grant_sentence("google") ==
               "Google refused the saved sign-in client, so the sign-in could not renew."
    end

    test "the vendor's own words carry the status, the code and the description", %{
      detail: detail
    } do
      assert ClientRejection.vendor_words(detail) ==
               "X answered HTTP 401 unauthorized_client: Missing valid authorization header"

      assert ClientRejection.vendor_words(%{detail | description: nil}) ==
               "X answered HTTP 401 unauthorized_client"
    end

    test "no sentence advises a command that cannot fix a refused client", %{detail: detail} do
      for text <- [ClientRejection.sentence(detail), ClientRejection.grant_sentence("x")] do
        refute text =~ "fermix auth login"
        refute text =~ "restart"
      end
    end
  end

  # Every reader of the stored quarantine status must treat a refused client as
  # quarantined. The readers are code sites, not a registry, so the case set is
  # derived from the source: any module that spells one of the quarantine values
  # the store carries must spell `client_rejected` too. A reader added later that
  # checks only `reauthorization_required` fails here instead of treating a
  # refused client as a ready one.
  describe "no reader treats client_rejected as ready" do
    @apps Path.expand("../../../..", __DIR__)
    @quarantine_values ["reauthorization_required", "invalidated"]

    test "every module that reads or writes a stored quarantine value knows client_rejected" do
      spelling = quarantine_modules()

      assert Enum.any?(spelling, &String.ends_with?(&1, "plugins/status.ex"))
      assert Enum.any?(spelling, &String.ends_with?(&1, "providers/selection.ex"))

      missing = Enum.reject(spelling, &("client_rejected" in literals(&1)))

      assert missing == [],
             "these modules spell a stored quarantine value but not client_rejected: " <>
               inspect(Enum.map(missing, &Path.relative_to(&1, @apps)))
    end

    defp quarantine_modules do
      @apps
      |> Path.join("*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn file -> Enum.any?(@quarantine_values, &(&1 in literals(file))) end)
    end

    defp literals(file) do
      {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

      {_ast, found} =
        Macro.prewalk(ast, [], fn
          node, acc when is_binary(node) -> {node, [node | acc]}
          node, acc -> {node, acc}
        end)

      found
    end
  end
end
