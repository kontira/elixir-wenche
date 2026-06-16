defmodule Wenche.MvaMeldingTest do
  use ExUnit.Case, async: true

  alias Wenche.MvaMelding

  defp sample_mva_data do
    %{
      org_nummer: "912345678",
      termin: 1,
      year: 2025,
      system_name: "TestSystem",
      fastsatt_merverdiavgift: 1_500,
      linjer: [
        %{mva_kode: 3, grunnlag: 10_000, sats: 25, merverdiavgift: 2_500},
        %{mva_kode: 1, grunnlag: 4_000, sats: 25, merverdiavgift: 1_000}
      ]
    }
  end

  defp ok_xml do
    """
    <?xml version='1.0' encoding='UTF-8'?>
    <valideringsresultat xmlns="no:skatteetaten:fastsetting:avgift:mva:valideringsresultat:v1">
      <avvikVedMeldingslevering>ok</avvikVedMeldingslevering>
    </valideringsresultat>
    """
  end

  defp ugyldig_xml do
    """
    <?xml version='1.0' encoding='UTF-8'?>
    <valideringsresultat xmlns="no:skatteetaten:fastsetting:avgift:mva:valideringsresultat:v1">
      <avvikVedMeldingslevering>ugyldig skattemelding</avvikVedMeldingslevering>
      <avvik>
        <stiTilAvvik>//meldingskategori</stiTilAvvik>
        <mvaKode>null</mvaKode>
        <avviksinformasjon>
          <begrunnelse>Virksomheten er ikke registrert i Merverdiavgiftsregisteret med plikt til å levere mva-melding for alminnelig næring.</begrunnelse>
          <avvikstype>ugyldig skattemelding</avvikstype>
          <avvikKode>MVA_PLIKT_OPPGITT_MELDINGSKATEGORI_ALMINNELIG_NÆRING_FINNES_IKKE</avvikKode>
          <regelDefinisjon>R047</regelDefinisjon>
        </avviksinformasjon>
      </avvik>
    </valideringsresultat>
    """
  end

  defp send_xml(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.send_resp(status, body)
  end

  describe "valider/2" do
    test "returns parsed validation result on success" do
      Req.Test.stub(Wenche.MvaMelding, fn conn ->
        assert conn.method == "POST"
        assert conn.host == "idporten-api-test.sits.no"
        assert conn.request_path == "/api/mva/grensesnittstoette/mva-melding/valider"
        assert {"authorization", "Bearer test-token"} in conn.req_headers
        send_xml(conn, 200, ok_xml())
      end)

      assert {:ok, result} =
               MvaMelding.valider(sample_mva_data(),
                 token: "test-token",
                 env: "test",
                 req_options: [plug: {Req.Test, Wenche.MvaMelding}]
               )

      assert result.avvik_ved_meldingslevering == "ok"
      assert result.avvik == []
      assert is_binary(result.raw_xml)
      # The melding XML that was sent is surfaced for audit-trail persistence.
      assert is_binary(result.request_xml)
      assert result.request_xml =~ "<"
    end

    test "uses the documented production validation endpoint" do
      Req.Test.stub(Wenche.MvaMelding, fn conn ->
        assert conn.method == "POST"
        assert conn.host == "idporten.api.skatteetaten.no"
        assert conn.request_path == "/api/mva/grensesnittstoette/mva-melding/valider"
        send_xml(conn, 200, ok_xml())
      end)

      assert {:ok, %{avvik_ved_meldingslevering: "ok"}} =
               MvaMelding.valider(sample_mva_data(),
                 token: "test-token",
                 env: "prod",
                 req_options: [plug: {Req.Test, Wenche.MvaMelding}]
               )
    end

    test "parses avvik entries from an invalid validation result" do
      Req.Test.stub(Wenche.MvaMelding, fn conn ->
        send_xml(conn, 200, ugyldig_xml())
      end)

      assert {:ok, result} =
               MvaMelding.valider(sample_mva_data(),
                 token: "test-token",
                 env: "test",
                 req_options: [plug: {Req.Test, Wenche.MvaMelding}]
               )

      assert result.avvik_ved_meldingslevering == "ugyldig skattemelding"
      assert [avvik] = result.avvik
      assert avvik.sti_til_avvik == "//meldingskategori"
      assert avvik.mva_kode == "null"
      assert avvik.avvikstype == "ugyldig skattemelding"

      assert avvik.avvik_kode ==
               "MVA_PLIKT_OPPGITT_MELDINGSKATEGORI_ALMINNELIG_NÆRING_FINNES_IKKE"

      assert avvik.begrunnelse =~ "ikke registrert"
      assert avvik.regel_definisjon == "R047"
    end

    test "returns error on validation failure" do
      Req.Test.stub(Wenche.MvaMelding, fn conn ->
        send_xml(conn, 400, "<error>bad request</error>")
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
