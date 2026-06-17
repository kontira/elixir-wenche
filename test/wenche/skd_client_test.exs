defmodule Wenche.SkdClientTest do
  use ExUnit.Case, async: true

  alias Wenche.SkdClient

  @req_opts [plug: {Req.Test, Wenche.SkdClient}, retry: false]

  describe "new/2" do
    test "creates client with default prod env" do
      client = SkdClient.new("test-token")

      assert client.token == "test-token"
      assert client.base =~ "api.sits.no"
      assert client.req_options == []
    end

    test "creates client with test env" do
      client = SkdClient.new("test-token", env: "test")

      assert client.base =~ "api-test.sits.no"
    end

    test "stores req_options" do
      client = SkdClient.new("test-token", env: "test", req_options: @req_opts)

      assert client.req_options == @req_opts
    end

    test "raises on invalid env" do
      assert_raise ArgumentError, fn ->
        SkdClient.new("test-token", env: "invalid")
      end
    end
  end

  describe "req_options support" do
    test "send_hovedskjema passes req_options through" do
      Req.Test.stub(Wenche.SkdClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/1086H")

        # SKD returns the id as camelCase "hovedskjemaId".
        Req.Test.json(conn, %{"hovedskjemaId" => "abc-123"})
      end)

      client = SkdClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, "abc-123"} = SkdClient.send_hovedskjema(client, 2024, "<xml/>")
    end

    test "send_hovedskjema accepts the lowercase hovedskjemaid variant" do
      Req.Test.stub(Wenche.SkdClient, fn conn ->
        Req.Test.json(conn, %{"hovedskjemaid" => "abc-123"})
      end)

      client = SkdClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, "abc-123"} = SkdClient.send_hovedskjema(client, 2024, "<xml/>")
    end

    test "send_hovedskjema fails when a 2xx response carries no id" do
      Req.Test.stub(Wenche.SkdClient, fn conn ->
        Req.Test.json(conn, %{"feil" => "noe gikk galt"})
      end)

      client = SkdClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:error, {:hovedskjema_failed, 200, %{"feil" => "noe gikk galt"}}} =
               SkdClient.send_hovedskjema(client, 2024, "<xml/>")
    end

    test "send_underskjema passes req_options through" do
      Req.Test.stub(Wenche.SkdClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/1086U")

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{})
      end)

      client = SkdClient.new("test-token", env: "test", req_options: @req_opts)

      assert :ok = SkdClient.send_underskjema(client, 2024, "abc-123", "<xml/>")
    end

    test "bekreft passes req_options through" do
      Req.Test.stub(Wenche.SkdClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/bekreft")

        Req.Test.json(conn, %{"forsendelseId" => "fors-123", "dialogId" => "dlg-456"})
      end)

      client = SkdClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, body} = SkdClient.bekreft(client, 2024, "abc-123", 5)
      assert body["forsendelseId"] == "fors-123"
    end
  end
end
