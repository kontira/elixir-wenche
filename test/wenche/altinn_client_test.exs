defmodule Wenche.AltinnClientTest do
  use ExUnit.Case, async: true

  alias Wenche.AltinnClient

  @opts [req_options: [plug: {Req.Test, Wenche.AltinnClient}, retry: false], env: "test"]

  setup do
    Req.Test.stub(Wenche.AltinnClient, fn conn ->
      Req.Test.json(conn, %{})
    end)

    :ok
  end

  describe "new/2" do
    test "creates a client with default prod env" do
      client = AltinnClient.new("test-token")

      assert client.token == "test-token"
      assert client.env == "prod"
      assert client.apps_base =~ "altinn.no"
      assert client.req_options == []
    end

    test "creates a client with test env" do
      client = AltinnClient.new("test-token", env: "test")

      assert client.env == "test"
      assert client.apps_base =~ "tt02.altinn.no"
    end

    test "stores req_options" do
      client = AltinnClient.new("test-token", env: "test", req_options: [plug: {Req.Test, :test}])

      assert client.req_options == [plug: {Req.Test, :test}]
    end

    test "raises on invalid env" do
      assert_raise ArgumentError, fn ->
        AltinnClient.new("test-token", env: "invalid")
      end
    end
  end

  describe "struct-based API with req_options" do
    @struct_opts [
      plug: {Req.Test, Wenche.AltinnClient.Struct},
      retry: false
    ]

    test "opprett_instans passes req_options through" do
      Req.Test.stub(Wenche.AltinnClient.Struct, fn conn ->
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => "50012345/abc-123"})
      end)

      client = AltinnClient.new("test-token", env: "test", req_options: @struct_opts)

      assert {:ok, body} = AltinnClient.opprett_instans(client, "aarsregnskap", "912345678")
      assert body["id"] == "50012345/abc-123"
    end

    test "opprett_instans skattemelding targets the formueinntekt-skattemelding-v2 app" do
      Req.Test.stub(Wenche.AltinnClient.Struct, fn conn ->
        assert conn.host == "skd.apps.tt02.altinn.no"
        assert conn.request_path == "/skd/formueinntekt-skattemelding-v2/instances"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => "50012345/abc-123"})
      end)

      client = AltinnClient.new("test-token", env: "test", req_options: @struct_opts)
      assert {:ok, _} = AltinnClient.opprett_instans(client, "skattemelding", "912345678")
    end

    test "hent_status passes req_options through" do
      Req.Test.stub(Wenche.AltinnClient.Struct, fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, %{"id" => "50012345/abc-123", "status" => %{"isArchived" => false}})
      end)

      client = AltinnClient.new("test-token", env: "test", req_options: @struct_opts)
      instans = %{"id" => "50012345/abc-123"}

      assert {:ok, body} = AltinnClient.hent_status(client, "aarsregnskap", instans)
      assert body["status"]["isArchived"] == false
    end

    test "fullfoor_instans passes req_options through" do
      Req.Test.stub(Wenche.AltinnClient.Struct, fn conn ->
        assert conn.method == "PUT"
        Req.Test.json(conn, %{"ended" => "2025-01-15T12:00:00Z"})
      end)

      client = AltinnClient.new("test-token", env: "test", req_options: @struct_opts)
      instans = %{"id" => "50012345/abc-123"}

      assert {:ok, _url} = AltinnClient.fullfoor_instans(client, "aarsregnskap", instans)
    end

    test "oppdater_data_element passes req_options through" do
      Req.Test.stub(Wenche.AltinnClient.Struct, fn conn ->
        assert conn.method == "PUT"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"id" => "data-element-id"})
      end)

      client = AltinnClient.new("test-token", env: "test", req_options: @struct_opts)

      instans = %{
        "id" => "50012345/abc-123",
        "data" => [%{"dataType" => "hovedskjema", "id" => "data-element-id"}]
      }

      assert {:ok, body} =
               AltinnClient.oppdater_data_element(
                 client,
                 "aarsregnskap",
                 instans,
                 "hovedskjema",
                 "<xml>test</xml>",
                 "application/xml"
               )

      assert body["id"] == "data-element-id"
    end
  end

  # Legacy API tests
  describe "create_instance/4 (legacy)" do
    test "creates an instance on success" do
      Req.Test.stub(Wenche.AltinnClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/instances")

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "id" => "50012345/abc-123-def",
          "status" => %{"isArchived" => false}
        })
      end)

      assert {:ok, body} =
               AltinnClient.create_instance("test-token", "912345678", "brg/aarsregnskap", @opts)

      assert body["id"] == "50012345/abc-123-def"
    end

    test "returns error on failure" do
      Req.Test.stub(Wenche.AltinnClient, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "Forbidden"})
      end)

      assert {:error, {:altinn_create_instance_error, 403, _}} =
               AltinnClient.create_instance("bad-token", "912345678", "brg/aarsregnskap", @opts)
    end
  end

  describe "update_data_element/7 (legacy)" do
    test "uploads data successfully" do
      Req.Test.stub(Wenche.AltinnClient, fn conn ->
        assert conn.method == "POST"
        assert String.contains?(conn.request_path, "/data")

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => "data-element-id"})
      end)

      assert {:ok, body} =
               AltinnClient.update_data_element(
                 "test-token",
                 "50012345/abc-123-def",
                 "brg/aarsregnskap",
                 "hovedskjema",
                 "application/xml",
                 "<xml>test</xml>",
                 @opts
               )

      assert body["id"] == "data-element-id"
    end
  end

  describe "complete_instance/4 (legacy)" do
    test "completes an instance" do
      Req.Test.stub(Wenche.AltinnClient, fn conn ->
        assert conn.method == "PUT"
        assert String.contains?(conn.request_path, "/process/next")

        Req.Test.json(conn, %{"ended" => "2025-01-15T12:00:00Z"})
      end)

      assert {:ok, body} =
               AltinnClient.complete_instance(
                 "test-token",
                 "50012345/abc-123-def",
                 "brg/aarsregnskap",
                 @opts
               )

      assert body["ended"]
    end

    test "returns error on failure" do
      Req.Test.stub(Wenche.AltinnClient, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error" => "Conflict"})
      end)

      assert {:error, {:altinn_complete_error, 409, _}} =
               AltinnClient.complete_instance(
                 "test-token",
                 "50012345/abc-123-def",
                 "brg/aarsregnskap",
                 @opts
               )
    end
  end

  describe "get_status/4 (legacy)" do
    test "returns instance status" do
      Req.Test.stub(Wenche.AltinnClient, fn conn ->
        assert conn.method == "GET"

        Req.Test.json(conn, %{
          "id" => "50012345/abc-123-def",
          "status" => %{"isArchived" => true}
        })
      end)

      assert {:ok, body} =
               AltinnClient.get_status(
                 "test-token",
                 "50012345/abc-123-def",
                 "brg/aarsregnskap",
                 @opts
               )

      assert body["status"]["isArchived"] == true
    end
  end
end
