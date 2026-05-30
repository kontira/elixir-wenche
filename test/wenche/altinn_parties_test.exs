defmodule Wenche.AltinnPartiesTest do
  use ExUnit.Case, async: true

  alias Wenche.AltinnParties

  @stub_req_opts [plug: {Req.Test, Wenche.AltinnParties}, retry: false]

  @org_party %{
    "partyUuid" => "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    "name" => "Example AS",
    "organizationNumber" => "123456789",
    "personId" => nil,
    "partyId" => 12_345,
    "type" => "Organization",
    "unitType" => "AS",
    "isDeleted" => false,
    "onlyHierarchyElementWithNoAccess" => false,
    "authorizedResources" => [],
    "authorizedRoles" => ["DAGL"],
    "subunits" => []
  }

  defp opts(extra \\ []), do: Keyword.merge([req_options: @stub_req_opts], extra)

  describe "hent_parter/2" do
    test "returns list of parties on 200" do
      Req.Test.stub(Wenche.AltinnParties, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path =~ "/accessmanagement/api/v1/authorizedparties"

        Req.Test.json(conn, [@org_party])
      end)

      assert {:ok, [party]} = AltinnParties.hent_parter("altinn-token", opts())
      assert party["organizationNumber"] == "123456789"
      assert party["name"] == "Example AS"
    end

    test "returns error on non-200" do
      Req.Test.stub(Wenche.AltinnParties, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "unauthorized"})
      end)

      assert {:error, {:altinn_parties_error, 401, _}} =
               AltinnParties.hent_parter("bad-token", opts())
    end

    test "returns error on request failure" do
      Req.Test.stub(Wenche.AltinnParties, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, {:altinn_parties_request_failed, _}} =
               AltinnParties.hent_parter("altinn-token", opts())
    end

    test "uses test env URL" do
      Req.Test.stub(Wenche.AltinnParties, fn conn ->
        assert conn.host =~ "tt02.altinn.no"
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = AltinnParties.hent_parter("token", opts(env: "test"))
    end

    test "raises on invalid env" do
      assert_raise ArgumentError, fn ->
        AltinnParties.hent_parter("token", env: "invalid")
      end
    end
  end

  describe "har_tilgang_til_org?/3" do
    test "returns true when org number is in parties list" do
      Req.Test.stub(Wenche.AltinnParties, fn conn ->
        Req.Test.json(conn, [@org_party])
      end)

      assert {:ok, true} =
               AltinnParties.har_tilgang_til_org?("token", "123456789", opts())
    end

    test "returns false when org number is not in parties list" do
      Req.Test.stub(Wenche.AltinnParties, fn conn ->
        Req.Test.json(conn, [@org_party])
      end)

      assert {:ok, false} =
               AltinnParties.har_tilgang_til_org?("token", "999999999", opts())
    end

    test "returns false for empty parties list" do
      Req.Test.stub(Wenche.AltinnParties, fn conn ->
        Req.Test.json(conn, [])
      end)

      assert {:ok, false} =
               AltinnParties.har_tilgang_til_org?("token", "123456789", opts())
    end

    test "passes through API error" do
      Req.Test.stub(Wenche.AltinnParties, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "forbidden"})
      end)

      assert {:error, {:altinn_parties_error, 403, _}} =
               AltinnParties.har_tilgang_til_org?("token", "123456789", opts())
    end
  end
end
