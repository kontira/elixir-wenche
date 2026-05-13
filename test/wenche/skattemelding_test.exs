defmodule Wenche.SkattemeldingTest do
  use ExUnit.Case, async: true

  alias Wenche.Skattemelding

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
    Selskap,
    SkattemeldingKonfig
  }

  def sample_selskap do
    %Selskap{
      navn: "Test AS",
      org_nummer: "912345678",
      daglig_leder: "Ola Nordmann",
      styreleder: "Kari Nordmann",
      forretningsadresse: "Storgata 1, 0001 Oslo",
      stiftelsesaar: 2020,
      aksjekapital: 30_000
    }
  end

  def sample_regnskap do
    %Aarsregnskap{
      selskap: sample_selskap(),
      regnskapsaar: 2025,
      resultatregnskap: %Resultatregnskap{
        driftsinntekter: %Driftsinntekter{salgsinntekter: 500_000},
        driftskostnader: %Driftskostnader{andre_driftskostnader: 350_000},
        finansposter: %Finansposter{
          andre_finansinntekter: 10_000,
          rentekostnader: 5_000
        }
      },
      balanse: %Balanse{
        eiendeler: %Eiendeler{
          anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 200_000},
          omloepmidler: %Omloepmidler{bankinnskudd: 300_000}
        },
        egenkapital_og_gjeld: %EgenkapitalOgGjeld{
          egenkapital: %Egenkapital{aksjekapital: 100_000, annen_egenkapital: 150_000},
          langsiktig_gjeld: %LangsiktigGjeld{laan_fra_aksjonaer: 100_000},
          kortsiktig_gjeld: %KortsiktigGjeld{leverandoergjeld: 150_000}
        }
      }
    }
  end

  describe "generer/2" do
    test "generates a report with company info" do
      konfig = %SkattemeldingKonfig{}
      report = Skattemelding.generer(sample_regnskap(), konfig)

      assert report =~ "Test AS"
      assert report =~ "912345678"
      assert report =~ "2025"
    end

    test "includes RF-1167 section" do
      konfig = %SkattemeldingKonfig{}
      report = Skattemelding.generer(sample_regnskap(), konfig)

      assert report =~ "RF-1167"
      assert report =~ "NÆRINGSOPPGAVE"
      assert report =~ "DRIFTSINNTEKTER"
      assert report =~ "DRIFTSKOSTNADER"
    end

    test "includes RF-1028 section" do
      konfig = %SkattemeldingKonfig{}
      report = Skattemelding.generer(sample_regnskap(), konfig)

      assert report =~ "RF-1028"
      assert report =~ "SKATTEMELDING FOR AS"
      assert report =~ "22 %"
    end

    test "includes balance section" do
      konfig = %SkattemeldingKonfig{}
      report = Skattemelding.generer(sample_regnskap(), konfig)

      assert report =~ "BALANSE"
      assert report =~ "EIENDELER"
      assert report =~ "EGENKAPITAL OG GJELD"
    end

    test "applies fritaksmetoden for subsidiary dividends" do
      regnskap = %{
        sample_regnskap()
        | resultatregnskap: %Resultatregnskap{
            driftsinntekter: %Driftsinntekter{salgsinntekter: 0},
            driftskostnader: %Driftskostnader{andre_driftskostnader: 5_000},
            finansposter: %Finansposter{utbytte_fra_datterselskap: 100_000}
          }
      }

      konfig = %SkattemeldingKonfig{anvend_fritaksmetoden: true, eierandel_datterselskap: 100}
      report = Skattemelding.generer(regnskap, konfig)

      assert report =~ "fritatt"
    end

    test "applies 3% rule for <90% ownership" do
      regnskap = %{
        sample_regnskap()
        | resultatregnskap: %Resultatregnskap{
            driftsinntekter: %Driftsinntekter{salgsinntekter: 0},
            driftskostnader: %Driftskostnader{andre_driftskostnader: 5_000},
            finansposter: %Finansposter{utbytte_fra_datterselskap: 100_000}
          }
      }

      konfig = %SkattemeldingKonfig{anvend_fritaksmetoden: true, eierandel_datterselskap: 50}
      report = Skattemelding.generer(regnskap, konfig)

      assert report =~ "97 %"
      assert report =~ "3 %"
    end

    test "applies loss carryforward" do
      regnskap = %{
        sample_regnskap()
        | resultatregnskap: %Resultatregnskap{
            driftsinntekter: %Driftsinntekter{salgsinntekter: 100_000},
            driftskostnader: %Driftskostnader{andre_driftskostnader: 0},
            finansposter: %Finansposter{}
          }
      }

      konfig = %SkattemeldingKonfig{underskudd_til_fremfoering: 50_000}
      report = Skattemelding.generer(regnskap, konfig)

      assert report =~ "fremf. underskudd"
    end
  end

  describe "beregn/2" do
    test "computes basic tax calculation without fritaksmetoden" do
      konfig = %SkattemeldingKonfig{}
      result = Skattemelding.beregn(sample_regnskap(), konfig)

      assert result.selskap.navn == "Test AS"
      assert result.regnskapsaar == 2025
      assert result.rf_1167.driftsinntekter.sum == 500_000
      assert result.rf_1167.driftskostnader.sum == 350_000
      assert result.rf_1167.driftsresultat == 150_000
      # driftsresultat(150k) + utbytte(0) + andre_finans(10k) - fin_kostnader(5k) = 155k
      assert result.rf_1028.skattepliktig_inntekt_brutto == 155_000
      assert result.rf_1028.beregnet_skatt == ceil(155_000 * 0.22)
      assert result.rf_1028.fritaksmetoden == nil
    end

    test "applies fritaksmetoden with >=90% ownership" do
      regnskap = %{
        sample_regnskap()
        | resultatregnskap: %Resultatregnskap{
            driftsinntekter: %Driftsinntekter{salgsinntekter: 0},
            driftskostnader: %Driftskostnader{andre_driftskostnader: 5_000},
            finansposter: %Finansposter{utbytte_fra_datterselskap: 100_000}
          }
      }

      konfig = %SkattemeldingKonfig{anvend_fritaksmetoden: true, eierandel_datterselskap: 100}
      result = Skattemelding.beregn(regnskap, konfig)

      assert result.rf_1028.fritaksmetoden.fritatt_utbytte == 100_000
      assert result.rf_1028.fritaksmetoden.skattepliktig_utbytte == 0
      assert result.rf_1028.fritaksmetoden.eierandel_over_90 == true
    end

    test "applies 3% sjablonregel with <90% ownership" do
      regnskap = %{
        sample_regnskap()
        | resultatregnskap: %Resultatregnskap{
            driftsinntekter: %Driftsinntekter{salgsinntekter: 0},
            driftskostnader: %Driftskostnader{andre_driftskostnader: 5_000},
            finansposter: %Finansposter{utbytte_fra_datterselskap: 100_000}
          }
      }

      konfig = %SkattemeldingKonfig{anvend_fritaksmetoden: true, eierandel_datterselskap: 50}
      result = Skattemelding.beregn(regnskap, konfig)

      assert result.rf_1028.fritaksmetoden.skattepliktig_utbytte == 3_000
      assert result.rf_1028.fritaksmetoden.fritatt_utbytte == 97_000
      assert result.rf_1028.fritaksmetoden.eierandel_over_90 == false
    end

    test "applies loss carryforward deduction" do
      regnskap = %{
        sample_regnskap()
        | resultatregnskap: %Resultatregnskap{
            driftsinntekter: %Driftsinntekter{salgsinntekter: 100_000},
            driftskostnader: %Driftskostnader{andre_driftskostnader: 0},
            finansposter: %Finansposter{}
          }
      }

      konfig = %SkattemeldingKonfig{underskudd_til_fremfoering: 40_000}
      result = Skattemelding.beregn(regnskap, konfig)

      assert result.rf_1028.fradrag_underskudd == 40_000
      assert result.rf_1028.skattepliktig_inntekt_netto == 60_000
      assert result.rf_1028.underskudd_til_fremfoering == 0
    end

    test "includes sammenligning when foregaaende_aar present" do
      regnskap = %{
        sample_regnskap()
        | foregaaende_aar_resultat: %Resultatregnskap{
            driftsinntekter: %Driftsinntekter{salgsinntekter: 400_000},
            driftskostnader: %Driftskostnader{andre_driftskostnader: 300_000},
            finansposter: %Finansposter{}
          },
          foregaaende_aar_balanse: %Balanse{
            eiendeler: %Eiendeler{
              anleggsmidler: %Anleggsmidler{},
              omloepmidler: %Omloepmidler{bankinnskudd: 200_000}
            },
            egenkapital_og_gjeld: %EgenkapitalOgGjeld{
              egenkapital: %Egenkapital{aksjekapital: 100_000, annen_egenkapital: 100_000},
              langsiktig_gjeld: %LangsiktigGjeld{},
              kortsiktig_gjeld: %KortsiktigGjeld{}
            }
          }
      }

      konfig = %SkattemeldingKonfig{}
      result = Skattemelding.beregn(regnskap, konfig)

      assert result.sammenligning != nil
      assert result.sammenligning.regnskapsaar == 2025
      assert result.sammenligning.foregaaende_aar == 2024
      assert result.egenkapitalnote.har_fjoraar == true
    end

    test "sammenligning is nil without foregaaende_aar" do
      konfig = %SkattemeldingKonfig{}
      result = Skattemelding.beregn(sample_regnskap(), konfig)

      assert result.sammenligning == nil
      assert result.egenkapitalnote.har_fjoraar == false
    end

    test "balanse section includes correct sums" do
      konfig = %SkattemeldingKonfig{}
      result = Skattemelding.beregn(sample_regnskap(), konfig)

      assert result.balanse.eiendeler.sum == 500_000
      assert result.balanse.egenkapital_og_gjeld.sum == 500_000
      assert result.balanse.i_balanse == true
    end
  end

  describe "valider/4 fetches partsnummer from Skatteetaten" do
    @req_opts [plug: {Req.Test, Wenche.SkdSkattemeldingClient}, retry: false]

    test "calls hent_partsnummer first, then valider with that partsnummer in XML" do
      utkast_xml =
        ~s|<?xml version="1.0"?><skattemelding xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:upersonlig:ekstern:v5"><partsnummer>9001</partsnummer><inntektsaar>2025</inntektsaar></skattemelding>|

      ref = make_ref()

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        case conn.method do
          "GET" ->
            assert conn.request_path =~ "/2025/912345678"
            refute conn.request_path =~ "/utkast/"

            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, utkast_xml)

          "POST" ->
            assert conn.request_path =~ "/valider/2025/912345678"
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(self(), {ref, body})
            Req.Test.json(conn, %{"ok" => true})
        end
      end)

      skd_client =
        Wenche.SkdSkattemeldingClient.new("token", env: "test", req_options: @req_opts)

      assert {:ok, %{"ok" => true}} =
               Skattemelding.valider(sample_regnskap(), %SkattemeldingKonfig{}, skd_client)

      assert_received {^ref, posted_body}
      assert posted_body =~ "skattemeldingOgNaeringsspesifikasjonRequest"

      decoded =
        Regex.scan(~r{<content>([^<]+)</content>}, posted_body)
        |> Enum.map_join("\n", fn [_, b64] -> Base.decode64!(b64) end)

      assert decoded =~ "<partsnummer>9001</partsnummer>"
      assert decoded =~ "<partsreferanse>9001</partsreferanse>"
      refute decoded =~ "<partsnummer>912345678</partsnummer>"
    end

    test "returns {:error, {:utkast_referanse_failed, _}} when utkast fails" do
      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      skd_client =
        Wenche.SkdSkattemeldingClient.new("token", env: "test", req_options: @req_opts)

      assert {:error, {:utkast_referanse_failed, _}} =
               Skattemelding.valider(sample_regnskap(), %SkattemeldingKonfig{}, skd_client)
    end

    test "valider posts dokumentreferanseTilGjeldendeDokument from utkast response" do
      # Mirror Skatteetaten's documented response shape (see
      # docs/test/testinnsending/upersonlig-as-2022.ipynb).
      inner_xml =
        ~s|<?xml version="1.0"?><skattemelding xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:upersonlig:ekstern:v5"><partsnummer>9001</partsnummer><inntektsaar>2025</inntektsaar></skattemelding>|

      inner_b64 = Base.encode64(inner_xml)

      wrapper = """
      <skattemeldingOgNaeringsspesifikasjonforespoerselResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:forespoersel:response:v2">
        <dokumenter>
          <skattemeldingdokument>
            <id>SKI:755:9876543</id>
            <encoding>utf-8</encoding>
            <content>#{inner_b64}</content>
            <type>skattemeldingUpersonligUtkast</type>
          </skattemeldingdokument>
        </dokumenter>
      </skattemeldingOgNaeringsspesifikasjonforespoerselResponse>
      """

      response_ok = """
      <skattemeldingOgNaeringsspesifikasjonResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:response:v2">
        <resultatAvValidering>validertUtenFeil</resultatAvValidering>
      </skattemeldingOgNaeringsspesifikasjonResponse>
      """

      ref = make_ref()

      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, wrapper)

          "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(self(), {ref, body})

            conn
            |> Plug.Conn.put_resp_content_type("application/xml")
            |> Plug.Conn.resp(200, response_ok)
        end
      end)

      skd_client =
        Wenche.SkdSkattemeldingClient.new("token", env: "test", req_options: @req_opts)

      assert {:ok, _body} =
               Skattemelding.valider(sample_regnskap(), %SkattemeldingKonfig{}, skd_client)

      assert_received {^ref, posted_body}

      assert posted_body =~ "<dokumentreferanseTilGjeldendeDokument>"
      assert posted_body =~ "<dokumenttype>skattemeldingUpersonlig</dokumenttype>"
      assert posted_body =~ "<dokumentidentifikator>SKI:755:9876543</dokumentidentifikator>"
    end

    test "honors explicit :partsnummer opt without fetching utkast" do
      Req.Test.stub(Wenche.SkdSkattemeldingClient, fn conn ->
        refute conn.method == "GET"
        assert conn.request_path =~ "/valider/"
        Req.Test.json(conn, %{"ok" => true})
      end)

      skd_client =
        Wenche.SkdSkattemeldingClient.new("token", env: "test", req_options: @req_opts)

      assert {:ok, _} =
               Skattemelding.valider(sample_regnskap(), %SkattemeldingKonfig{}, skd_client,
                 partsnummer: 7777
               )
    end
  end
end
