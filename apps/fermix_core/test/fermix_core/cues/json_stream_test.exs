defmodule FermixCore.Cues.JsonStreamTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.JsonStream

  # A broker's news stream as a source names it: messages typed by "T",
  # stories "n", errors "error". Every value is invented.
  @source %{
    url: "wss://stream.example.com/v2/news",
    id_path: "id",
    revision_path: "updated_at",
    type_path: "T",
    subject_path: "symbols.0",
    time_path: "created_at",
    item_types: ["n"],
    error_types: ["error"]
  }

  defp story(id) do
    %{
      "T" => "n",
      "id" => id,
      "headline" => "Kettering Rail wins the Ashby line contract",
      "symbols" => ["KTRL", "ASHB"],
      "created_at" => "2026-10-12T13:59:00Z",
      "updated_at" => "2026-10-12T13:59:30Z"
    }
  end

  defp read_text(value, source \\ @source),
    do: JsonStream.read({:text, Jason.encode!(value)}, source)

  describe "read/2" do
    test "a list frame gives each message; stories are items read by the paths" do
      assert {:ok, %{entries: [{:item, item}], over_limit: 0}} = read_text([story(31_407_220)])

      assert item.item_id == "31407220"
      assert item.revision == "2026-10-12T13:59:30Z"
      assert item.type == "n"
      assert item.subject == "KTRL"
      assert item.occurred_at == ~U[2026-10-12 13:59:00Z]
      assert item.data == story(31_407_220)
      assert item.datacontenttype == "application/json"
    end

    test "control messages are skipped, by type, inside the same frame as stories" do
      frame = [
        %{"T" => "success", "msg" => "connected"},
        %{"T" => "subscription", "news" => ["*"]},
        story(31_407_221)
      ]

      assert {:ok, %{entries: [:skip, :skip, {:item, %{item_id: "31407221"}}]}} =
               read_text(frame)
    end

    test "an error message carries the service's words, canonical and bounded" do
      error = %{"T" => "error", "code" => 406, "msg" => "connection limit exceeded"}

      assert {:ok, %{entries: [{:service_error, words}]}} = read_text([error])
      assert words == ~s({"T":"error","code":406,"msg":"connection limit exceeded"})

      long = %{"T" => "error", "msg" => String.duplicate("é\n\t", 400)}
      assert {:ok, %{entries: [{:service_error, words}]}} = read_text([long])
      assert byte_size(words) <= 512
      assert String.valid?(words)
      refute words =~ ~r/[\x00-\x1F]/
    end

    test "a message with no id is a reject" do
      assert {:ok, %{entries: [{:reject, sentence}]}} = read_text([Map.delete(story(1), "id")])
      assert sentence =~ "no id"
    end

    test "an object frame is one message, and nothing at items_path skips the frame" do
      assert {:ok, %{entries: [{:item, %{item_id: "9"}}]}} = read_text(story(9))

      nested = Map.put(@source, :items_path, "data")

      assert {:ok, %{entries: [{:item, _}, {:item, _}]}} =
               read_text(%{"data" => [story(1), story(2)]}, nested)

      assert {:ok, %{entries: [:skip], over_limit: 0}} = read_text(%{"ping" => 1}, nested)
    end

    test "more than 100 messages keeps the first 100 and counts the rest" do
      assert {:ok, %{entries: entries, over_limit: 20}} = read_text(Enum.map(1..120, &story/1))
      assert length(entries) == 100
      assert {:item, %{item_id: "1"}} = hd(entries)
    end

    test "with no item_types every message that is not an error is an item" do
      source = Map.delete(@source, :item_types)
      control = %{"T" => "success", "id" => 5}

      assert {:ok, %{entries: [{:item, %{item_id: "5"}}]}} = read_text([control], source)
    end

    test "a message read with no type path has the type stream.item" do
      source = Map.drop(@source, [:type_path, :item_types, :error_types])

      assert {:ok, %{entries: [{:item, %{type: "stream.item"}}]}} =
               read_text([Map.delete(story(8), "T")], source)
    end

    test "a frame that is not JSON and a binary frame are one reject each" do
      assert {:ok, %{entries: [{:reject, _}], over_limit: 0}} =
               JsonStream.read({:text, "[{\"T\":"}, @source)

      assert {:ok, %{entries: [{:reject, sentence}], over_limit: 0}} =
               JsonStream.read({:binary, <<0, 1, 2>>}, @source)

      assert sentence =~ "binary"
    end

    test "a frame over 1 MiB is refused before it is decoded" do
      big = String.duplicate("x", JsonStream.max_frame_bytes() + 1)
      assert JsonStream.read({:text, big}, @source) == {:error, :frame_too_large}
      assert JsonStream.read({:binary, big}, @source) == {:error, :frame_too_large}
      assert JsonStream.max_frame_bytes() == 1024 * 1024
    end
  end

  describe "signing in" do
    @auth ~s({"action":"auth","key":"{{key}}","secret":"{{secret}}"})

    test "the secrets a sign-in uses: by header or by placeholder, key first" do
      assert JsonStream.secret_fields(%{}) == []
      assert JsonStream.secret_fields(%{key_header: "X-Feed-Key"}) == [:key]
      assert JsonStream.secret_fields(%{secret_header: "X-Feed-Secret"}) == [:secret]
      assert JsonStream.secret_fields(%{auth_message: @auth}) == [:key, :secret]

      assert JsonStream.secret_fields(%{auth_message: ~s({"token":"{{secret}}"})}) ==
               [:secret]
    end

    test "headers carry each stored value whole; a value with a line break is refused by field" do
      source = %{key_header: "X-Feed-Key", secret_header: "Authorization"}
      secrets = %{key: "PK31ZQ", secret: "Bearer sk-77rq"}

      assert JsonStream.headers(source, secrets) ==
               {:ok, [{"X-Feed-Key", "PK31ZQ"}, {"Authorization", "Bearer sk-77rq"}]}

      assert JsonStream.headers(%{}, %{}) == {:ok, []}

      assert JsonStream.headers(source, %{secrets | secret: "sk\r\nX-Evil: 1"}) ==
               {:error, {:unsendable_secret, :secret}}
    end

    test "the sign-in message is filled JSON-escaped, then the message after connecting" do
      source = %{auth_message: @auth, subscribe_message: ~s({"action":"subscribe"})}
      secrets = %{key: "PK31ZQ", secret: ~S(a"b\c)}

      assert {:ok, [sign_in, subscribe]} = JsonStream.messages(source, secrets)
      assert sign_in == ~S({"action":"auth","key":"PK31ZQ","secret":"a\"b\\c"})
      assert Jason.decode!(sign_in)["secret"] == ~S(a"b\c)
      assert subscribe == ~s({"action":"subscribe"})

      assert JsonStream.messages(%{}, %{}) == {:ok, []}

      assert JsonStream.messages(source, %{secrets | key: <<0xFF>>}) ==
               {:error, {:unsendable_secret, :key}}
    end
  end

  describe "check_config/1" do
    test "a full section passes" do
      section =
        Map.merge(@source, %{
          key_header: "X-Feed-Key",
          secret_header: "X-Feed-Secret",
          auth_message: @auth,
          subscribe_message: ~s({"action":"subscribe","news":["*"]})
        })

      assert JsonStream.check_config(section) == :ok
    end

    test "each refusal names its field" do
      cases = [
        {%{url: "wss:///news"}, :url, "must name a host"},
        {%{key_header: "X Feed"}, :key_header, "is not a header name"},
        {%{key_header: "Host"}, :key_header, "sets itself"},
        {%{secret_header: "sec-websocket-protocol"}, :secret_header, "sets itself"},
        {%{key_header: "X-Token", secret_header: "x-token"}, :secret_header, "must differ"},
        {%{auth_message: ~s({"key":"{{key}}","pass":"{{password}}"})}, :auth_message,
         "no placeholder but"},
        {%{auth_message: ~s({"key":{{key}}})}, :auth_message, "inside a JSON string"},
        {%{auth_message: ~s("{{key}}")}, :auth_message, "object or list"},
        {%{auth_message: ~s({"k":"#{String.duplicate("x", 4100)}"})}, :auth_message, "4 KiB"},
        {%{subscribe_message: ~s({"key":"{{key}}"})}, :subscribe_message, "no placeholder"},
        {%{subscribe_message: "subscribe news"}, :subscribe_message, "object or list"},
        {%{id_path: "data..id"}, :id_path, "dot path"},
        {%{type_path: nil}, :item_types, "needs type_path"}
      ]

      for {change, field, words} <- cases do
        section = @source |> Map.merge(change) |> drop_nil()

        assert {:error, ^field, sentence} = JsonStream.check_config(section),
               "#{inspect(change)} was not refused under #{field}"

        assert sentence =~ words
      end
    end

    test "a placeholder inside a string with a quote of its own still passes" do
      assert JsonStream.check_config(%{auth_message: ~s({"params":"key={{key}}&x=\\"y\\""})}) ==
               :ok
    end
  end

  defp drop_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
