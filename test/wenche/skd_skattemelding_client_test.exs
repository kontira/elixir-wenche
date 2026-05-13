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
        assert headers["content-type"] == "application/xml;charset=UTF-8"

        Req.Test.json(conn, %{"resultat" => "ok"})
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, _body} =
               SkdSkattemeldingClient.valider(client, 2024, "912345678", "<xml/>")
    end
  end

  describe "hent_forhandsutfylt/3 and hent_partsnummer/3" do
    test "returns inner XML when response is raw skattemelding XML" do
      raw_xml = ~s(<?xml version="1.0"?><skattemelding xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:upersonlig:ekstern:v5"><partsnummer>424242</partsnummer><inntektsaar>2024</inntektsaar></skattemelding>)

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path =~ "/2024/912345678"
        refute conn.request_path =~ "/utkast/"

        headers = Map.new(conn.req_headers)
        assert headers["accept"] == "application/xml"

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, raw_xml)
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, xml} = SkdSkattemeldingClient.hent_forhandsutfylt(client, 2024, "912345678")
      assert xml == raw_xml

      assert {:ok, 424_242} = SkdSkattemeldingClient.hent_partsnummer(client, 2024, "912345678")
    end

    test "unwraps forespoersel response envelope" do
      inner_xml = ~s(<?xml version="1.0"?><skattemelding xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:upersonlig:ekstern:v5"><partsnummer>4711</partsnummer><inntektsaar>2024</inntektsaar></skattemelding>)

      inner_b64 = Base.encode64(inner_xml)

      wrapper = ~s|<?xml version="1.0"?><forespoerselResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:forespoersel:response:v2"><dokumentidentifikator>doc-1</dokumentidentifikator><content>#{inner_b64}</content></forespoerselResponse>|

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, wrapper)
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, xml} = SkdSkattemeldingClient.hent_forhandsutfylt(client, 2024, "912345678")
      assert xml == inner_xml

      assert {:ok, 4711} = SkdSkattemeldingClient.hent_partsnummer(client, 2024, "912345678")
    end

    test "returns error on non-200 response" do
      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:error, {:utkast_failed, 404, "not found"}} =
               SkdSkattemeldingClient.hent_forhandsutfylt(client, 2024, "912345678")
    end
  end

  describe "hent_utkast_referanse/3" do
    # Real-world response shape captured from Skatteetaten's docs notebook
    # (docs/test/testinnsending/upersonlig-as-2022.ipynb):
    #
    #   GET https://idporten-api-test.sits.no/api/skattemelding/v2/2023/313010511
    #   → skattemeldingOgNaeringsspesifikasjonforespoerselResponse with
    #     <skattemeldingdokument><id>SKI:755:134559</id>...
    test "extracts partsnummer + skattemelding dokumentidentifikator from real response shape" do
      inner_xml =
        ~s|<?xml version="1.0" encoding="UTF-8"?><skattemelding xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:upersonlig:ekstern:v5"><partsnummer>300146577</partsnummer><inntektsaar>2023</inntektsaar></skattemelding>|

      inner_b64 = Base.encode64(inner_xml)

      wrapper = """
      <?xml version="1.0" ?>
      <skattemeldingOgNaeringsspesifikasjonforespoerselResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:forespoersel:response:v2">
        <dokumenter>
          <skattemeldingdokument>
            <id>SKI:755:134559</id>
            <encoding>utf-8</encoding>
            <content>#{inner_b64}</content>
            <type>skattemeldingUpersonligUtkast</type>
          </skattemeldingdokument>
        </dokumenter>
      </skattemeldingOgNaeringsspesifikasjonforespoerselResponse>
      """

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, wrapper)
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, ref} = SkdSkattemeldingClient.hent_utkast_referanse(client, 2023, "313010511")
      assert ref.partsnummer == 300_146_577
      assert ref.skattemelding_id == "SKI:755:134559"
      assert ref.naering_id == nil
    end

    test "extracts naeringsspesifikasjon dokumentidentifikator when present" do
      inner_xml =
        ~s|<?xml version="1.0"?><skattemelding xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:upersonlig:ekstern:v5"><partsnummer>4711</partsnummer><inntektsaar>2024</inntektsaar></skattemelding>|

      inner_b64 = Base.encode64(inner_xml)
      ne_b64 = Base.encode64("<naeringsspesifikasjon/>")

      wrapper = """
      <skattemeldingOgNaeringsspesifikasjonforespoerselResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:forespoersel:response:v2">
        <dokumenter>
          <skattemeldingdokument>
            <id>SKI:755:200001</id>
            <encoding>utf-8</encoding>
            <content>#{inner_b64}</content>
            <type>skattemeldingUpersonligUtkast</type>
          </skattemeldingdokument>
          <naeringsspesifikasjondokument>
            <id>SKI:755:200002</id>
            <encoding>utf-8</encoding>
            <content>#{ne_b64}</content>
          </naeringsspesifikasjondokument>
        </dokumenter>
      </skattemeldingOgNaeringsspesifikasjonforespoerselResponse>
      """

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, wrapper)
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, ref} = SkdSkattemeldingClient.hent_utkast_referanse(client, 2024, "912345678")
      assert ref.partsnummer == 4711
      assert ref.skattemelding_id == "SKI:755:200001"
      assert ref.naering_id == "SKI:755:200002"
    end
  end

  describe "valider/4 semantic result detection" do
    test "treats validertMedFeil response as an error" do
      response = """
      <?xml version="1.0" encoding="UTF-8"?>
      <skattemeldingOgNaeringsspesifikasjonResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:response:v2">
        <avvikVedValidering>
          <avvik><avvikstype>innkommendeForespoerselManglerReferanseTilGjeldendeSkattemelding</avvikstype></avvik>
        </avvikVedValidering>
        <resultatAvValidering>validertMedFeil</resultatAvValidering>
        <aarsakTilValidertMedFeil>innkommendeForespoerselManglerReferanseTilGjeldendeSkattemelding</aarsakTilValidertMedFeil>
      </skattemeldingOgNaeringsspesifikasjonResponse>
      """

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, response)
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:error, {:validation_failed, {:validert_med_feil, reasons}, _body}} =
               SkdSkattemeldingClient.valider(client, 2025, "933773965", "<xml/>")

      assert "innkommendeForespoerselManglerReferanseTilGjeldendeSkattemelding" in reasons
    end

    test "treats validertUtenFeil response as success" do
      response = """
      <skattemeldingOgNaeringsspesifikasjonResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:response:v2">
        <resultatAvValidering>validertUtenFeil</resultatAvValidering>
      </skattemeldingOgNaeringsspesifikasjonResponse>
      """

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, response)
      end)

      client =
        SkdSkattemeldingClient.new("test-token", env: "test", req_options: @req_opts)

      assert {:ok, _body} =
               SkdSkattemeldingClient.valider(client, 2025, "933773965", "<xml/>")
    end
  end
end
