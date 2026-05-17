defmodule Wenche.MvaMeldingTest do
  use ExUnit.Case, async: true

  alias Wenche.MvaMelding

  defp sample_mva_data do
    %{
      org_nummer: "912345678",
      termin: 1,
      year: 2025,
      system_name: "TestSystem",
      fastsatt_merverdiavgift: 1500,
      linjer: [
        %{mva_kode: 3, grunnlag: 10000, sats: 25, merverdiavgift: 2500},
        %{mva_kode: 1, grunnlag: 4000, sats: 25, merverdiavgift: 1000}
      ]
    }
  end

  describe "valider/2" do
    test "returns ok with validation result on success" do
      Req.Test.stub(Wenche.MvaMelding, fn conn ->
        assert conn.method == "POST"
        assert {"authorization", "Bearer test-token"} in conn.req_headers
        Req.Test.json(conn, %{"status" => "ok", "errors" => []})
      end)

      assert {:ok, %{"status" => "ok"}} =
               MvaMelding.valider(sample_mva_data(),
                 token: "test-token",
                 env: "test",
                 req_options: [plug: {Req.Test, Wenche.MvaMelding}]
               )
    end

    test "returns error on validation failure" do
      Req.Test.stub(Wenche.MvaMelding, fn conn ->
        Plug.Conn.send_resp(conn, 400, Jason.encode!(%{"errors" => ["invalid period"]}))
      end)

      assert {:error, {:valider_failed, 400, _}} =
               MvaMelding.valider(sample_mva_data(),
                 token: "test-token",
                 env: "test",
                 req_options: [plug: {Req.Test, Wenche.MvaMelding}]
               )
    end
  end

end
