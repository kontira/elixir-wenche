defmodule Wenche.SkattemeldingPersonligTest do
  use ExUnit.Case, async: true

  alias Wenche.SkattemeldingPersonlig
  alias Wenche.SkdSkattemeldingClient

  alias Wenche.Models.{
    Aarsregnskap,
    Anleggsmidler,
    Balanse,
    Driftsinntekter,
    Driftskostnader,
    Egenkapital,
    EgenkapitalOgGjeld,
    Eiendeler,
    Finansposter,
    KortsiktigGjeld,
    LangsiktigGjeld,
    Omloepmidler,
    Resultatregnskap,
    Selskap
  }

  @req_opts [plug: {Req.Test, Wenche.SkdSkattemeldingClient}, retry: false]

  def sample_regnskap do
    %Aarsregnskap{
      selskap: %Selskap{
        navn: "Ola Nordmann ENK",
        org_nummer: "912345678",
        forretningsadresse: "Storgata 1, 0001 Oslo",
        stiftelsesaar: 2022,
        aksjekapital: 0
      },
      regnskapsaar: 2025,
      resultatregnskap: %Resultatregnskap{
        driftsinntekter: %Driftsinntekter{salgsinntekter: 400_000, andre_driftsinntekter: 0},
        driftskostnader: %Driftskostnader{
          loennskostnader: 0,
          avskrivninger: 0,
          andre_driftskostnader: 150_000
        },
        finansposter: %Finansposter{
          utbytte_fra_datterselskap: 0,
          andre_finansinntekter: 0,
          rentekostnader: 2_000,
          andre_finanskostnader: 0
        }
      },
      balanse: %Balanse{
        eiendeler: %Eiendeler{
          anleggsmidler: %Anleggsmidler{
            aksjer_i_datterselskap: 0,
            andre_aksjer: 0,
            langsiktige_fordringer: 0
          },
          omloepmidler: %Omloepmidler{kortsiktige_fordringer: 20_000, bankinnskudd: 130_000}
        },
        egenkapital_og_gjeld: %EgenkapitalOgGjeld{
          egenkapital: %Egenkapital{aksjekapital: 0, overkursfond: 0, annen_egenkapital: 120_000},
          langsiktig_gjeld: %LangsiktigGjeld{laan_fra_aksjonaer: 0, andre_langsiktige_laan: 0},
          kortsiktig_gjeld: %KortsiktigGjeld{
            leverandoergjeld: 30_000,
            skyldige_offentlige_avgifter: 0,
            annen_kortsiktig_gjeld: 0
          }
        }
      }
    }
  end

  defp client, do: SkdSkattemeldingClient.new("token", env: "test", req_options: @req_opts)

  describe "beregn/2" do
    test "returns the skattemessig næringsresultat (driftsresultat − finanskostnader)" do
      result = SkattemeldingPersonlig.beregn(sample_regnskap())

      # 400_000 − 150_000 − 2_000 = 248_000
      assert result.skattemessig_naeringsresultat == 248_000
      assert result.regnskapsaar == 2025
      assert result.selskap.org_nummer == "912345678"
    end
  end

  describe "valider/3" do
    setup do
      inner_xml =
        ~s|<?xml version="1.0"?><skattemelding xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:ekstern:v13"><partsreferanse>9001</partsreferanse><inntektsaar>2025</inntektsaar></skattemelding>|

      wrapper = """
      <skattemeldingOgNaeringsspesifikasjonforespoerselResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:forespoersel:response:v2">
        <dokumenter>
          <skattemeldingdokument>
            <id>SKI:755:PERSONLIG1</id>
            <encoding>utf-8</encoding>
            <content>#{Base.encode64(inner_xml)}</content>
            <type>skattemeldingPersonligUtkast</type>
          </skattemeldingdokument>
          <naeringsspesifikasjondokument>
            <id>SKI:755:NAERING1</id>
          </naeringsspesifikasjondokument>
        </dokumenter>
      </skattemeldingOgNaeringsspesifikasjonforespoerselResponse>
      """

      %{wrapper: wrapper}
    end

    test "fetches partsreferanse, posts a skattemeldingPersonlig envelope with dokumentreferanse",
         %{wrapper: wrapper} do
      response_ok = """
      <skattemeldingOgNaeringsspesifikasjonResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:response:v2">
        <resultatAvValidering>validertUtenFeil</resultatAvValidering>
      </skattemeldingOgNaeringsspesifikasjonResponse>
      """

      ref = make_ref()

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        case conn.method do
          "GET" ->
            assert conn.request_path =~ "/2025/912345678"

            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, wrapper)

          "POST" ->
            assert conn.request_path =~ "/valider/2025/912345678"
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(self(), {ref, body})

            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, response_ok)
        end
      end)

      assert {:ok, _body} = SkattemeldingPersonlig.valider(sample_regnskap(), client())

      assert_received {^ref, posted}

      # The skattemelding dokument is the personlig type, and the resolved
      # partsreferanse (9001) replaced the org_nummer placeholder in the inner doc.
      assert posted =~ "<type>skattemeldingPersonlig</type>"
      refute posted =~ "<type>skattemeldingUpersonlig</type>"

      decoded = decode_first_dokument(posted)
      assert decoded =~ "<partsreferanse>9001</partsreferanse>"
      refute decoded =~ "<partsreferanse>912345678</partsreferanse>"

      # The næringsspesifikasjon (second <dokument>) carries the personinntekt allocation.
      naering_decoded = decode_second_dokument(posted)
      assert naering_decoded =~ "<beregnetPersoninntekt>"
      assert naering_decoded =~ "<fordeltBeregnetPersoninntekt>"
      assert naering_decoded =~ "<prosent>100</prosent>"

      # dokumentreferanse points back at both draft documents.
      assert posted =~ "<dokumenttype>skattemeldingPersonlig</dokumenttype>"
      assert posted =~ "<dokumentidentifikator>SKI:755:PERSONLIG1</dokumentidentifikator>"
      assert posted =~ "<dokumenttype>naeringsspesifikasjon</dokumenttype>"
      assert posted =~ "<dokumentidentifikator>SKI:755:NAERING1</dokumentidentifikator>"
    end

    test "surfaces a validertMedFeil response as an error", %{wrapper: wrapper} do
      response_feil = """
      <skattemeldingOgNaeringsspesifikasjonResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:response:v2">
        <resultatAvValidering>validertMedFeil</resultatAvValidering>
        <avvik><avvikstype>kodeXYZ</avvikstype></avvik>
      </skattemeldingOgNaeringsspesifikasjonResponse>
      """

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, wrapper)

          "POST" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, response_feil)
        end
      end)

      assert {:error, {:validation_failed, {:validert_med_feil, ["kodeXYZ"]}, _body}} =
               SkattemeldingPersonlig.valider(sample_regnskap(), client())
    end

    test "keys the draft lookup, /valider and <tin> on :partsidentifikator (owner fnr)",
         %{wrapper: wrapper} do
      response_ok = """
      <skattemeldingOgNaeringsspesifikasjonResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:response:v2">
        <resultatAvValidering>validertUtenFeil</resultatAvValidering>
      </skattemeldingOgNaeringsspesifikasjonResponse>
      """

      ref = make_ref()

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        case conn.method do
          "GET" ->
            # Draft is fetched for the owner (fnr), not the org number.
            assert conn.request_path =~ "/2025/12345678901"
            refute conn.request_path =~ "912345678"

            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, wrapper)

          "POST" ->
            assert conn.request_path =~ "/valider/2025/12345678901"
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(self(), {ref, body})

            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, response_ok)
        end
      end)

      assert {:ok, _body} =
               SkattemeldingPersonlig.valider(sample_regnskap(), client(),
                 partsidentifikator: "12345678901"
               )

      assert_received {^ref, posted}
      # Envelope identifies the taxpayer by the owner's fnr, not the org number.
      assert posted =~ "<tin>12345678901</tin>"
      refute posted =~ "<tin>912345678</tin>"
    end

    test "honors an explicit :partsreferanse opt without fetching the draft" do
      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        refute conn.method == "GET"
        assert conn.request_path =~ "/valider/"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(self(), {:posted, body})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert {:ok, _} =
               SkattemeldingPersonlig.valider(sample_regnskap(), client(), partsreferanse: 7_777)

      assert_received {:posted, posted}
      assert decode_first_dokument(posted) =~ "<partsreferanse>7777</partsreferanse>"
    end
  end

  describe "parse_etter_beregning/1" do
    test "extracts partsreferanse + inntektsaar from a personlig EtterBeregning doc" do
      inner =
        ~s|<skattemelding><partsreferanse>9001</partsreferanse><inntektsaar>2025</inntektsaar></skattemelding>|

      body = """
      <resp>
        <dokument>
          <type>skattemeldingPersonligEtterBeregning</type>
          <encoding>utf-8</encoding>
          <content>#{Base.encode64(inner)}</content>
        </dokument>
      </resp>
      """

      assert %{partsreferanse: 9001, inntektsaar: 2025} =
               SkattemeldingPersonlig.parse_etter_beregning(body)
    end

    test "returns an empty map when no EtterBeregning document is present" do
      assert SkattemeldingPersonlig.parse_etter_beregning("<resp/>") == %{}
    end
  end

  # Decodes the base64 <content> of the first <dokument> — the skattemelding document.
  defp decode_first_dokument(envelope) do
    [[_, b64] | _] = Regex.scan(~r{<content>([^<]+)</content>}, envelope)
    Base.decode64!(String.replace(b64, ~r/\s+/, ""))
  end

  # Decodes the base64 <content> of the second <dokument> — the næringsspesifikasjon.
  defp decode_second_dokument(envelope) do
    [_, [_, b64]] = Regex.scan(~r{<content>([^<]+)</content>}, envelope)
    Base.decode64!(String.replace(b64, ~r/\s+/, ""))
  end
end
