defmodule Wenche.SkdSkattemeldingClientTest do
  use ExUnit.Case, async: true

  alias Wenche.SkdSkattemeldingClient

  @req_opts [plug: {Req.Test, Wenche.SkdSkattemeldingClient}, retry: false]

  describe "new/2" do
    test "creates client with default prod env" do
      client = SkdSkattemeldingClient.new("test-token")

      assert client.token == "test-token"
      assert client.base =~ "api.skatteetaten.no"
      assert client.req_options == []
    end

    test "creates client with test env" do
      client = SkdSkattemeldingClient.new("test-token", env: "test")

      assert client.base =~ "api-test.sits.no"
    end

    test "stores req_options" do
      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert client.req_options == @req_opts
    end

    test "raises on invalid env" do
      assert_raise ArgumentError, fn ->
        SkdSkattemeldingClient.new("test-token", env: "invalid")
      end
    end
  end

  describe "req_options support" do
    test "hent_utkast passes req_options through" do
      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        assert conn.method == "GET"
        assert String.contains?(conn.request_path, "/utkast/")

        Req.Test.json(conn, %{"dokumentidentifikator" => "dok-123", "content" => "<xml/>"})
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, body} = SkdSkattemeldingClient.hent_utkast(client, 2024, "912345678")
      assert body["dokumentidentifikator"] == "dok-123"
    end

    test "valider passes req_options through" do
      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/valider/")

        Req.Test.json(conn, %{"resultat" => "ok"})
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, body} =
               SkdSkattemeldingClient.valider(client, 2024, "912345678", "<xml/>")

      assert body["resultat"] == "ok"
    end

    test "valider sends Accept: application/xml" do
      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        headers = Map.new(conn.req_headers)
        assert headers["accept"] == "application/xml;charset=UTF-8"
        assert headers["content-type"] == "application/xml"

        Req.Test.json(conn, %{"resultat" => "ok"})
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, _body} =
               SkdSkattemeldingClient.valider(client, 2024, "912345678", "<xml/>")
    end
  end
end
