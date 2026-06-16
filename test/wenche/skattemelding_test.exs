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

    test "applies holding-driven :permanent_forskjeller and ignores eierandel_datterselskap" do
      # Mirrors the production Witted scenario:
      #   revenue 30 000, costs 36 313, andre finans 67, finanskostnad 521,
      #   utbytte 50 429 (booked in P&L). Holding-driven breakdown reverses
      #   the full utbytte (50 429), adds 3 % back (1 513), reverses gevinst
      #   (71). Expected skattepliktig brutto = -5 325.
      regnskap = %{
        sample_regnskap()
        | resultatregnskap: %Resultatregnskap{
            driftsinntekter: %Driftsinntekter{salgsinntekter: 30_000},
            driftskostnader: %Driftskostnader{andre_driftskostnader: 36_313},
            finansposter: %Finansposter{
              utbytte_fra_datterselskap: 50_429,
              andre_finansinntekter: 67,
              rentekostnader: 521
            }
          }
      }

      konfig = %SkattemeldingKonfig{
        # eierandel = 100 used to silently activate konsernunntak and skip
        # the 3 % add-back; with :permanent_forskjeller set, it must be ignored.
        eierandel_datterselskap: 100,
        permanent_forskjeller: [
          %{type: :tilbakefoeringAvInntektsfoertUtbytte, beloep: 50_429},
          %{type: :skattepliktigDelAvUtbytterOgUtdelinger, beloep: 1_513},
          %{type: :regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter, beloep: 71},
          %{type: :regnskapsmessigTapVedRealisasjonAvFinansielleInstrumenter, beloep: 0}
        ]
      }

      result = Skattemelding.beregn(regnskap, konfig)

      # 30 000 - 36 313 + 50 429 + 67 - 521 = 43 662 (regnskapsmessig)
      # 43 662 - 50 429 + 1 513 - 71 + 0 = -5 325 (skattemessig)
      assert result.rf_1028.skattepliktig_inntekt_brutto == -5_325
      assert result.rf_1028.beregnet_skatt == 0
      assert result.rf_1028.underskudd_til_fremfoering == 5_325
    end

    test "Decimal beloep in :permanent_forskjeller rounds the sum once for brutto" do
      # Real-world rounding (Hübenthal Invest 2025): rounded per line the
      # pieces are 50 429 / 1 513 / 71 / 367 and the integer sum is -48 620.
      # The raw decimals sum to -48 620.6949 → -48 621 when rounded once,
      # which is what Skatteetaten / Fiken compute. Pass Decimal beloep and
      # beregn/2 sums-then-rounds.
      regnskap = %{
        sample_regnskap()
        | resultatregnskap: %Resultatregnskap{
            driftsinntekter: %Driftsinntekter{salgsinntekter: 30_000},
            driftskostnader: %Driftskostnader{andre_driftskostnader: 36_313},
            finansposter: %Finansposter{
              utbytte_fra_datterselskap: 50_429,
              andre_finansinntekter: 67,
              rentekostnader: 522
            }
          }
      }

      breakdown_decimals = [
        %{type: :tilbakefoeringAvInntektsfoertUtbytte, beloep: Decimal.new("50429.17")},
        %{type: :skattepliktigDelAvUtbytterOgUtdelinger, beloep: Decimal.new("1512.8751")},
        %{
          type: :regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter,
          beloep: Decimal.new("71.22")
        },
        %{
          type: :regnskapsmessigTapVedRealisasjonAvFinansielleInstrumenter,
          beloep: Decimal.new("366.82")
        }
      ]

      result =
        Skattemelding.beregn(regnskap, %SkattemeldingKonfig{
          permanent_forskjeller: breakdown_decimals
        })

      # regnskapsmessig 43 661 + round_half_up(-48 620.6949) = 43 661 - 48 621 = -4 960
      assert result.rf_1028.skattepliktig_inntekt_brutto == -4_960
      assert result.rf_1028.underskudd_til_fremfoering == 4_960

      # The legacy integer path still works (back-compat with callers that
      # pre-round) but loses the fractional cents: -50 429 + 1 513 - 71 + 367
      # = -48 620, brutto = -4 959.
      breakdown_ints =
        Enum.map(breakdown_decimals, fn entry ->
          %{entry | beloep: Decimal.round(entry.beloep, 0, :half_up) |> Decimal.to_integer()}
        end)

      int_result =
        Skattemelding.beregn(regnskap, %SkattemeldingKonfig{permanent_forskjeller: breakdown_ints})

      assert int_result.rf_1028.skattepliktig_inntekt_brutto == -4_959
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

      assert {:ok, %Wenche.SubmissionResult{response: %{"ok" => true}, documents: documents}} =
               Skattemelding.valider(sample_regnskap(), %SkattemeldingKonfig{}, skd_client)

      assert Enum.map(documents, & &1.name) == ["skattemelding", "naering", "request"]
      assert Enum.all?(documents, &(is_binary(&1.content) and &1.content != ""))

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

  describe "parse_etter_beregning/1" do
    test "extracts SKD-computed numbers from a Witted-shaped validation response" do
      inner =
        ~s|<?xml version="1.0" encoding="UTF-8"?>| <>
          ~s|<skattemelding xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:upersonlig:ekstern:v5">| <>
          ~s|<partsnummer>3002203783</partsnummer>| <>
          ~s|<inntektsaar>2025</inntektsaar>| <>
          ~s|<inntektOgUnderskudd>| <>
          ~s|<underskuddTilFremfoering>| <>
          ~s|<fremfoertUnderskuddFraTidligereAar><beloepSomHeltall>18225</beloepSomHeltall></fremfoertUnderskuddFraTidligereAar>| <>
          ~s|<fremfoerbartUnderskuddIInntekt><beloep><beloepSomHeltall>23550</beloepSomHeltall></beloep></fremfoerbartUnderskuddIInntekt>| <>
          ~s|</underskuddTilFremfoering>| <>
          ~s|<inntektFoerFradragForEventueltAvgittKonsernbidrag><beloepSomHeltall>-5325</beloepSomHeltall></inntektFoerFradragForEventueltAvgittKonsernbidrag>| <>
          ~s|<samletUnderskudd><beloep><beloepSomHeltall>5325</beloepSomHeltall></beloep></samletUnderskudd>| <>
          ~s|</inntektOgUnderskudd>| <>
          ~s|</skattemelding>|

      envelope =
        ~s|<skattemeldingOgNaeringsspesifikasjonResponse xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:response:v2">| <>
          ~s|<dokumenter>| <>
          ~s|<dokument>| <>
          ~s|<type>skattemeldingUpersonligEtterBeregning</type>| <>
          ~s|<encoding>utf-8</encoding>| <>
          ~s|<content>#{Base.encode64(inner)}</content>| <>
          ~s|</dokument>| <>
          ~s|</dokumenter>| <>
          ~s|<resultatAvValidering>validertUtenFeil</resultatAvValidering>| <>
          ~s|</skattemeldingOgNaeringsspesifikasjonResponse>|

      assert %{
               partsnummer: 3_002_203_783,
               inntektsaar: 2025,
               inntekt_foer_fradrag_for_eventuelt_avgitt_konsernbidrag: -5_325,
               samlet_underskudd: 5_325,
               fremfoert_underskudd_fra_tidligere_aar: 18_225,
               fremfoerbart_underskudd_i_inntekt: 23_550
             } = Skattemelding.parse_etter_beregning(envelope)
    end

    test "returns an empty map when no EtterBeregning document is present" do
      assert Skattemelding.parse_etter_beregning("<other-xml/>") == %{}
      assert Skattemelding.parse_etter_beregning(nil) == %{}
    end

    test "returns nil for fields that aren't emitted (loss year has no samletInntekt)" do
      inner =
        ~s|<?xml version="1.0"?><skattemelding><partsnummer>123</partsnummer><inntektsaar>2025</inntektsaar></skattemelding>|

      envelope =
        ~s|<resp><dokument><type>skattemeldingUpersonligEtterBeregning</type><encoding>utf-8</encoding><content>#{Base.encode64(inner)}</content></dokument></resp>|

      result = Skattemelding.parse_etter_beregning(envelope)

      assert result.partsnummer == 123
      assert result.inntektsaar == 2025
      assert result.samlet_inntekt == nil
      assert result.samlet_underskudd == nil
    end
  end
end
