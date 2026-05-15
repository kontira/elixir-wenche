defmodule Wenche.SkattemeldingXmlTest do
  use ExUnit.Case, async: true

  alias Wenche.SkattemeldingXml

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
        driftsinntekter: %Driftsinntekter{salgsinntekter: 500_000, andre_driftsinntekter: 10_000},
        driftskostnader: %Driftskostnader{
          loennskostnader: 200_000,
          avskrivninger: 20_000,
          andre_driftskostnader: 130_000
        },
        finansposter: %Finansposter{
          utbytte_fra_datterselskap: 50_000,
          andre_finansinntekter: 5_000,
          rentekostnader: 10_000,
          andre_finanskostnader: 2_000
        }
      },
      balanse: %Balanse{
        eiendeler: %Eiendeler{
          anleggsmidler: %Anleggsmidler{
            aksjer_i_datterselskap: 200_000,
            andre_aksjer: 50_000,
            langsiktige_fordringer: 30_000
          },
          omloepmidler: %Omloepmidler{
            kortsiktige_fordringer: 80_000,
            bankinnskudd: 300_000
          }
        },
        egenkapital_og_gjeld: %EgenkapitalOgGjeld{
          egenkapital: %Egenkapital{
            aksjekapital: 100_000,
            overkursfond: 50_000,
            annen_egenkapital: 260_000
          },
          langsiktig_gjeld: %LangsiktigGjeld{
            laan_fra_aksjonaer: 100_000,
            andre_langsiktige_laan: 50_000
          },
          kortsiktig_gjeld: %KortsiktigGjeld{
            leverandoergjeld: 60_000,
            skyldige_offentlige_avgifter: 20_000,
            annen_kortsiktig_gjeld: 20_000
          }
        }
      }
    }
  end

  describe "generer_skattemelding_xml/3" do
    test "produces minimal XML with correct namespace" do
      xml = SkattemeldingXml.generer_skattemelding_xml(sample_regnskap(), %SkattemeldingKonfig{})

      assert xml =~
               ~s(xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:upersonlig:ekstern:v5")

      assert xml =~ "<skattemelding"
      assert xml =~ "</skattemelding>"
    end

    test "emits partsnummer and inntektsaar" do
      xml = SkattemeldingXml.generer_skattemelding_xml(sample_regnskap(), %SkattemeldingKonfig{})

      assert xml =~ "<partsnummer>912345678</partsnummer>"
      assert xml =~ "<inntektsaar>2025</inntektsaar>"
    end

    test "does NOT emit derived fields (Skatteetaten computes them)" do
      xml = SkattemeldingXml.generer_skattemelding_xml(sample_regnskap(), %SkattemeldingKonfig{})

      refute xml =~ "<inntekt>"
      refute xml =~ "<naeringsinntekt>"
      refute xml =~ "<samletInntekt>"
      refute xml =~ "<formueOgGjeld>"
      refute xml =~ "<bankinnskudd>"
      refute xml =~ "<samletGjeld>"
      refute xml =~ "nettoFormue"
      refute xml =~ "nettoformue"
    end

    test "emits underskuddTilFremfoering only when fremfoert_underskudd > 0" do
      konfig_zero = %SkattemeldingKonfig{underskudd_til_fremfoering: 0}
      xml_zero = SkattemeldingXml.generer_skattemelding_xml(sample_regnskap(), konfig_zero)
      refute xml_zero =~ "underskuddTilFremfoering"

      konfig_pos = %SkattemeldingKonfig{underskudd_til_fremfoering: 5_000}
      xml_pos = SkattemeldingXml.generer_skattemelding_xml(sample_regnskap(), konfig_pos)
      assert xml_pos =~ "<underskuddTilFremfoering>"
      assert xml_pos =~ "<fremfoertUnderskuddFraTidligereAar>"
      assert xml_pos =~ "<beloepSomHeltall>5000</beloepSomHeltall>"
    end

    test "respects :partsnummer option" do
      xml =
        SkattemeldingXml.generer_skattemelding_xml(
          sample_regnskap(),
          %SkattemeldingKonfig{},
          partsnummer: 4711
        )

      assert xml =~ "<partsnummer>4711</partsnummer>"
    end

    test "emits spesifikasjonAvForholdRelevanteForBeskatning when :aksjespesifikasjon is set" do
      holding = %{
        type: :aksje_i_aksjonaerregisteret,
        selskapets_navn: "Witted Minicorp I AS",
        selskapets_organisasjonsnummer: "933592731",
        landkode: "NO",
        er_omfattet_av_fritaksmetoden: true,
        aksjeklasse: "B",
        antall_aksjer: 0,
        utbytte: 50_429,
        gevinst_ved_realisasjon_av_aksje: 71,
        tap_ved_realisasjon_av_aksje: 0
      }

      xml =
        SkattemeldingXml.generer_skattemelding_xml(
          sample_regnskap(),
          %SkattemeldingKonfig{},
          aksjespesifikasjon: [holding]
        )

      assert xml =~ "<spesifikasjonAvForholdRelevanteForBeskatning>"
      assert xml =~ "<aksjeIAksjonaerregisteret>"
      assert xml =~ "<id>1</id>"

      assert xml =~
               "<selskapetsNavn><organisasjonsnavn>Witted Minicorp I AS</organisasjonsnavn></selskapetsNavn>"

      assert xml =~
               "<selskapetsOrganisasjonsnummer><organisasjonsnummer>933592731</organisasjonsnummer></selskapetsOrganisasjonsnummer>"

      assert xml =~ "<landkode><landkode>NO</landkode></landkode>"

      assert xml =~
               "<erOmfattetAvFritaksmetoden><boolsk>true</boolsk></erOmfattetAvFritaksmetoden>"

      # Input "B" is normalized to "b" — SKD's aksjeklasse kodeliste is
      # lowercase-only and would reject "B" with UgyldigKodelisteverdi.
      assert xml =~ "<aksjeklasse><aksjeklasse>b</aksjeklasse></aksjeklasse>"
      assert xml =~ "<utbytte><beloepSomHeltall>50429</beloepSomHeltall></utbytte>"

      assert xml =~
               "<gevinstVedRealisasjonAvAksje><beloepSomHeltall>71</beloepSomHeltall></gevinstVedRealisasjonAvAksje>"

      # antall is emitted even at 0; tap is suppressed at 0
      assert xml =~ "<antallAksjer><antall>0</antall></antallAksjer>"
      refute xml =~ "<tapVedRealisasjonAvAksje>"
    end

    test "omits spesifikasjonAvForholdRelevanteForBeskatning when list is empty" do
      xml = SkattemeldingXml.generer_skattemelding_xml(sample_regnskap(), %SkattemeldingKonfig{})

      refute xml =~ "spesifikasjonAvForholdRelevanteForBeskatning"
    end

    test "places spesifikasjonAvForholdRelevanteForBeskatning after inntektOgUnderskudd per XSD" do
      holding = %{
        type: :aksje_i_aksjonaerregisteret,
        selskapets_navn: "Witted",
        selskapets_organisasjonsnummer: "933592731",
        er_omfattet_av_fritaksmetoden: true,
        utbytte: 50_429
      }

      xml =
        SkattemeldingXml.generer_skattemelding_xml(
          sample_regnskap(),
          %SkattemeldingKonfig{underskudd_til_fremfoering: 1_000},
          aksjespesifikasjon: [holding]
        )

      inntekt_idx = :binary.match(xml, "<inntektOgUnderskudd>") |> elem(0)
      spec_idx = :binary.match(xml, "<spesifikasjonAvForholdRelevanteForBeskatning>") |> elem(0)
      assert spec_idx > inntekt_idx
    end
  end

  describe "generer_spesifikasjon_av_forhold_relevante_for_beskatning/1" do
    alias Wenche.SkattemeldingXml, as: SXML

    test "returns empty string for empty list" do
      assert SXML.generer_spesifikasjon_av_forhold_relevante_for_beskatning([]) == ""
    end

    test "emits aksjeIkkeIAksjonaerregisteret with custodian fields" do
      holding = %{
        type: :aksje_ikke_i_aksjonaerregisteret,
        kontofoerers_navn: "DNB Markets",
        kontonummer: "12345678901",
        selskapets_navn: "Acme Inc",
        landkode: "US",
        er_omfattet_av_fritaksmetoden: false,
        antall_aksjer: 100,
        utbytte: 5_000
      }

      xml = SXML.generer_spesifikasjon_av_forhold_relevante_for_beskatning([holding])

      assert xml =~ "<aksjeIkkeIAksjonaerregisteret>"

      assert xml =~
               "<kontofoerersNavn><organisasjonsnavn>DNB Markets</organisasjonsnavn></kontofoerersNavn>"

      assert xml =~ "<kontonummer><tekst>12345678901</tekst></kontonummer>"

      assert xml =~
               "<erOmfattetAvFritaksmetoden><boolsk>false</boolsk></erOmfattetAvFritaksmetoden>"

      assert xml =~ "<landkode><landkode>US</landkode></landkode>"
      refute xml =~ "selskapetsOrganisasjonsnummer"
    end

    test "emits verdipapirfond with aksjedel/rentedel realisasjoner" do
      holding = %{
        type: :verdipapirfond,
        fondets_navn: "KLP AksjeNorden",
        fondets_organisasjonsnummer: "981554242",
        landkode: "NO",
        er_omfattet_av_fritaksmetoden: true,
        antall_andeler: 42,
        utbytte: 1_200,
        gevinst_ved_realisasjon_av_andel_i_aksjedel: 500
      }

      xml = SXML.generer_spesifikasjon_av_forhold_relevante_for_beskatning([holding])

      assert xml =~ "<verdipapirfond>"

      assert xml =~
               "<fondetsNavn><organisasjonsnavn>KLP AksjeNorden</organisasjonsnavn></fondetsNavn>"

      assert xml =~
               "<gevinstVedRealisasjonAvAndelIAksjedel><beloepSomHeltall>500</beloepSomHeltall></gevinstVedRealisasjonAvAndelIAksjedel>"
    end

    test "assigns 1-based ids in order received" do
      holdings = [
        %{type: :aksje_i_aksjonaerregisteret, selskapets_navn: "A"},
        %{type: :aksje_i_aksjonaerregisteret, selskapets_navn: "B"}
      ]

      xml = SXML.generer_spesifikasjon_av_forhold_relevante_for_beskatning(holdings)

      [_, a_id] =
        Regex.run(
          ~r{<organisasjonsnavn>A</organisasjonsnavn></selskapetsNavn>.*?<id>(\d+)</id>}s,
          xml
        ) || ["", "?"]

      # The id is BEFORE the navn in the forekomst — look at the first forekomst's id.
      [_, first_id, second_id] =
        Regex.run(
          ~r{<aksjeIAksjonaerregisteret>\s*<id>(\d+)</id>.*?<aksjeIAksjonaerregisteret>\s*<id>(\d+)</id>}s,
          xml
        )

      assert first_id == "1"
      assert second_id == "2"
      _ = a_id
    end

    test "raises on unknown :type — better loud than a silently dropped holding" do
      assert_raise ArgumentError,
                   ~r/unsupported aksjespesifikasjon :type — :ukjent/,
                   fn ->
                     SXML.generer_spesifikasjon_av_forhold_relevante_for_beskatning([
                       %{type: :ukjent}
                     ])
                   end
    end

    test "lowercases aksjeklasse so it matches SKD's case-sensitive kodeliste" do
      for {input, expected} <- [
            {"A", "a"},
            {"B", "b"},
            {"Ordinaer", "ordinaer"},
            {"PREFERANSE", "preferanse"},
            {"a", "a"}
          ] do
        xml =
          SXML.generer_spesifikasjon_av_forhold_relevante_for_beskatning([
            %{type: :aksje_i_aksjonaerregisteret, aksjeklasse: input}
          ])

        assert xml =~ "<aksjeklasse><aksjeklasse>#{expected}</aksjeklasse></aksjeklasse>",
               "expected #{inspect(input)} to be normalized to #{inspect(expected)} in #{xml}"
      end
    end
  end

  describe "generer_naeringsspesifikasjon_xml/2" do
    test "produces v6 XML with correct namespace" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      assert xml =~
               ~s(xmlns="urn:no:skatteetaten:fastsetting:formueinntekt:naeringsspesifikasjon:ekstern:v6")

      assert xml =~ "<naeringsspesifikasjon"
      assert xml =~ "</naeringsspesifikasjon>"
    end

    test "emits partsreferanse and inntektsaar" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      assert xml =~ "<partsreferanse>912345678</partsreferanse>"
      assert xml =~ "<inntektsaar>2025</inntektsaar>"
    end

    test "does NOT emit derived sum/computed fields" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      refute xml =~ "<sumDriftsinntekt"
      refute xml =~ "<sumDriftskostnad"
      refute xml =~ "<sumFinansinntekt"
      refute xml =~ "<sumFinanskostnad"
      refute xml =~ "<driftsresultat"
      refute xml =~ "<aarsresultat"
    end

    test "emits virksomhet with correctly-spelled elements" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      assert xml =~ "<regnskapspliktstype>"
      refute xml =~ "<regnskapsplikttype>"
      assert xml =~ "<virksomhetstype>"
      assert xml =~ ~s(<dato>2025-01-01</dato>)
      assert xml =~ ~s(<dato>2025-12-31</dato>)
    end

    test "emits skalBekreftesAvRevisor (correct spelling, required)" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      assert xml =~ "<skalBekreftesAvRevisor>false</skalBekreftesAvRevisor>"
      refute xml =~ "skalBekreftedsAvRevisor"
    end

    test "skalBekreftesAvRevisor reflects regnskap.revideres" do
      regnskap = %{sample_regnskap() | revideres: true}
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(regnskap)

      assert xml =~ "<skalBekreftesAvRevisor>true</skalBekreftesAvRevisor>"
    end

    test "annenDriftskostnad children are <kostnad> not <inntekt>" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      assert xml =~ ~r/<annenDriftskostnad>\s*<kostnad>/
      refute xml =~ ~r/<annenDriftskostnad>\s*<inntekt>/
    end

    test "uses balanseregnskap not formueOgGjeld" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      assert xml =~ "<balanseregnskap>"
      refute xml =~ "<formueOgGjeld>"
    end

    test "balanseregnskap forekomst has id before beloep before type" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      # In balanseverdi, id must come first per XSD
      assert xml =~ ~r/<balanseverdi>\s*<id>/
    end

    test "forekomst id equals the kodeliste kode (Skatteetaten idAvvikerFraKrav rule)" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      # Skatteetaten validator requires <id> to equal the resultatOgBalanseregnskapstype kode.
      # A mismatch produces avvikstype=idAvvikerFraKrav.
      for kode <- ["3200", "6700", "8090", "8150", "1350", "1920", "2000", "2050", "2990"] do
        if xml =~ ">#{kode}<" do
          assert xml =~
                   ~r{<id>#{kode}</id>\s*(?:<beloep>|<type>\s*<resultatOgBalanseregnskapstype>#{kode})},
                 "expected <id>#{kode}</id> alongside resultatOgBalanseregnskapstype #{kode}"
        end
      end
    end

    test "uses 2025 kodeliste codes" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      # Resultatregnskap codes
      assert xml =~ ">3200<"
      assert xml =~ ">5000<"
      assert xml =~ ">6000<"
      assert xml =~ ">6700<"
      assert xml =~ ">8090<"
      assert xml =~ ">8050<"
      assert xml =~ ">8150<"
      assert xml =~ ">8160<"

      # Balanseregnskap codes
      assert xml =~ ">1313<"
      assert xml =~ ">1350<"
      assert xml =~ ">1390<"
      assert xml =~ ">1500<"
      assert xml =~ ">1920<"
      assert xml =~ ">2000<"
      assert xml =~ ">2020<"
      assert xml =~ ">2050<"
      assert xml =~ ">2250<"
      assert xml =~ ">2290<"
      assert xml =~ ">2400<"
      assert xml =~ ">2600<"
      assert xml =~ ">2990<"
    end

    test "negative annen_egenkapital uses udekketTap kode 2080" do
      regnskap = %{
        sample_regnskap()
        | balanse: %{
            sample_regnskap().balanse
            | egenkapital_og_gjeld: %{
                sample_regnskap().balanse.egenkapital_og_gjeld
                | egenkapital: %Egenkapital{
                    aksjekapital: 100_000,
                    overkursfond: 0,
                    annen_egenkapital: -50_000
                  }
              }
          }
      }

      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(regnskap)

      assert xml =~ ">2080<"
      refute xml =~ ">2050<"
    end

    test "respects :partsnummer option" do
      xml =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(), partsnummer: 4711)

      assert xml =~ "<partsreferanse>4711</partsreferanse>"
    end

    test "emits forskjellMellomRegnskapsmessigOgSkattemessigVerdi when :permanent_forskjeller is set" do
      forskjeller = [
        %{type: :tilbakefoeringAvInntektsfoertUtbytte, beloep: 50_429},
        %{type: :skattepliktigDelAvUtbytterOgUtdelinger, beloep: 1_513},
        %{type: :regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter, beloep: 71}
      ]

      xml =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(),
          permanent_forskjeller: forskjeller
        )

      assert xml =~ "<forskjellMellomRegnskapsmessigOgSkattemessigVerdi>"

      assert xml =~
               "<permanentForskjellstype><permanentForskjellstype>tilbakefoeringAvInntektsfoertUtbytte</permanentForskjellstype></permanentForskjellstype>"

      assert xml =~ "<beloep><beloep><beloep>50429</beloep></beloep></beloep>"
      assert xml =~ "<beloep><beloep><beloep>1513</beloep></beloep></beloep>"
      assert xml =~ "<beloep><beloep><beloep>71</beloep></beloep></beloep>"
      # ids assigned 1..3 in order
      assert xml =~ "<id>1</id>"
      assert xml =~ "<id>2</id>"
      assert xml =~ "<id>3</id>"
    end

    test "permanent_forskjeller block sits between balanseregnskap and virksomhet" do
      xml =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(),
          permanent_forskjeller: [
            %{type: :tilbakefoeringAvInntektsfoertUtbytte, beloep: 50_429}
          ]
        )

      balanse_idx = :binary.match(xml, "<balanseregnskap>") |> elem(0)

      block_idx =
        :binary.match(xml, "<forskjellMellomRegnskapsmessigOgSkattemessigVerdi>") |> elem(0)

      virksomhet_idx = :binary.match(xml, "<virksomhet>") |> elem(0)

      assert balanse_idx < block_idx
      assert block_idx < virksomhet_idx
    end

    test "drops zero-valued permanent forskjeller" do
      xml =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(),
          permanent_forskjeller: [
            %{type: :regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter, beloep: 0},
            %{type: :tilbakefoeringAvInntektsfoertUtbytte, beloep: 50_429}
          ]
        )

      assert xml =~ "tilbakefoeringAvInntektsfoertUtbytte"
      refute xml =~ "regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter"
    end

    test "omits the block entirely when list is empty" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      refute xml =~ "forskjellMellomRegnskapsmessigOgSkattemessigVerdi"
      refute xml =~ "permanentForskjell"
    end
  end

  describe "generer_request_xml/3" do
    test "wraps inner documents in request envelope" do
      xml =
        SkattemeldingXml.generer_request_xml(
          "<inner1/>",
          "<inner2/>",
          inntektsaar: 2025
        )

      assert xml =~ "<skattemeldingOgNaeringsspesifikasjonRequest"

      assert xml =~
               ~s(xmlns="no:skatteetaten:fastsetting:formueinntekt:skattemeldingognaeringsspesifikasjon:request:v2")
    end

    test "base64-encodes inner documents" do
      xml =
        SkattemeldingXml.generer_request_xml(
          "<skattemelding>test</skattemelding>",
          "<naeringsspesifikasjon>test</naeringsspesifikasjon>",
          inntektsaar: 2025
        )

      expected_b64_1 = Base.encode64("<skattemelding>test</skattemelding>")
      expected_b64_2 = Base.encode64("<naeringsspesifikasjon>test</naeringsspesifikasjon>")

      assert xml =~ "<content>#{expected_b64_1}</content>"
      assert xml =~ "<content>#{expected_b64_2}</content>"
    end

    test "includes document types" do
      xml = SkattemeldingXml.generer_request_xml("<a/>", "<b/>", inntektsaar: 2025)

      assert xml =~ "<type>skattemeldingUpersonlig</type>"
      assert xml =~ "<type>naeringsspesifikasjon</type>"
    end

    test "defaults to komplett and egenfastsetting" do
      xml = SkattemeldingXml.generer_request_xml("<a/>", "<b/>", inntektsaar: 2025)

      assert xml =~ "<innsendingstype>komplett</innsendingstype>"
      assert xml =~ "<innsendingsformaal>egenfastsetting</innsendingsformaal>"
      assert xml =~ "<opprettetAv>Wenche</opprettetAv>"
    end

    test "supports :opprettet_av override" do
      xml =
        SkattemeldingXml.generer_request_xml("<a/>", "<b/>",
          inntektsaar: 2025,
          opprettet_av: "Kontira"
        )

      assert xml =~ "<opprettetAv>Kontira</opprettetAv>"
      refute xml =~ "<opprettetAv>Wenche</opprettetAv>"
    end

    test "supports :tin (org_nummer)" do
      xml =
        SkattemeldingXml.generer_request_xml("<a/>", "<b/>", inntektsaar: 2025, tin: "933773965")

      assert xml =~ "<tin>933773965</tin>"
    end

    test "emits dokumentreferanseTilGjeldendeDokument from option" do
      xml =
        SkattemeldingXml.generer_request_xml(
          "<a/>",
          "<b/>",
          inntektsaar: 2025,
          dokumentreferanse: [{"skattemeldingUpersonlig", "ref-123"}]
        )

      assert xml =~ "<dokumentreferanseTilGjeldendeDokument>"
      assert xml =~ "<dokumenttype>skattemeldingUpersonlig</dokumenttype>"
      assert xml =~ "<dokumentidentifikator>ref-123</dokumentidentifikator>"
    end

    test "rejects invalid innsendingstype" do
      assert_raise ArgumentError, fn ->
        SkattemeldingXml.generer_request_xml("<a/>", "<b/>",
          inntektsaar: 2025,
          innsendingstype: "delvis"
        )
      end
    end

    test "rejects invalid innsendingsformaal" do
      assert_raise ArgumentError, fn ->
        SkattemeldingXml.generer_request_xml("<a/>", "<b/>",
          inntektsaar: 2025,
          innsendingsformaal: "annet"
        )
      end
    end

    test "rejects missing inntektsaar" do
      assert_raise ArgumentError, fn ->
        SkattemeldingXml.generer_request_xml("<a/>", "<b/>", [])
      end
    end
  end

  describe "hent_partsnummer/1" do
    test "extracts integer partsnummer from skattemelding XML" do
      xml = SkattemeldingXml.generer_skattemelding_xml(sample_regnskap(), %SkattemeldingKonfig{})

      assert {:ok, 912_345_678} = SkattemeldingXml.hent_partsnummer(xml)
    end

    test "returns error when partsnummer not present" do
      assert {:error, :partsnummer_not_found} = SkattemeldingXml.hent_partsnummer("<foo/>")
    end
  end

  describe "XSD validation (requires xmllint; XSDs vendored at priv/xsd/skatteetaten)" do
    @xsd_dir Path.join(:code.priv_dir(:wenche), "xsd/skatteetaten")

    @tag :xsd
    test "skattemelding (v5) validates" do
      xml = SkattemeldingXml.generer_skattemelding_xml(sample_regnskap(), %SkattemeldingKonfig{})
      assert_xml_valid!(xml, "#{@xsd_dir}/skattemeldingUpersonlig_v5_ekstern.xsd")
    end

    @tag :xsd
    test "skattemelding (v5) with fremfoert underskudd validates" do
      xml =
        SkattemeldingXml.generer_skattemelding_xml(
          sample_regnskap(),
          %SkattemeldingKonfig{underskudd_til_fremfoering: 7_500}
        )

      assert_xml_valid!(xml, "#{@xsd_dir}/skattemeldingUpersonlig_v5_ekstern.xsd")
    end

    @tag :xsd
    test "naeringsspesifikasjon (v6) validates" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())
      assert_xml_valid!(xml, "#{@xsd_dir}/naeringsspesifikasjon_v6_ekstern.xsd")
    end

    @tag :xsd
    test "request envelope (v2) validates" do
      sm = SkattemeldingXml.generer_skattemelding_xml(sample_regnskap(), %SkattemeldingKonfig{})
      ne = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      req =
        SkattemeldingXml.generer_request_xml(sm, ne, inntektsaar: 2025, tin: "912345678")

      assert_xml_valid!(req, "#{@xsd_dir}/skattemeldingognaeringsspesifikasjonrequest_v2.xsd")
    end

    @tag :xsd
    test "skattemelding with aksjespesifikasjon validates (mixed forekomst types)" do
      holdings = [
        %{
          type: :aksje_i_aksjonaerregisteret,
          selskapets_navn: "Witted Minicorp I AS",
          selskapets_organisasjonsnummer: "933592731",
          landkode: "NO",
          er_omfattet_av_fritaksmetoden: true,
          aksjeklasse: "B",
          antall_aksjer: 30,
          utbytte: 50_429,
          gevinst_ved_realisasjon_av_aksje: 71
        },
        %{
          type: :aksje_ikke_i_aksjonaerregisteret,
          kontofoerers_navn: "DNB Markets",
          kontonummer: "12345678901",
          selskapets_navn: "Acme Inc",
          landkode: "US",
          er_omfattet_av_fritaksmetoden: false,
          antall_aksjer: 100,
          utbytte: 5_000
        },
        %{
          type: :verdipapirfond,
          fondets_navn: "KLP AksjeNorden",
          fondets_organisasjonsnummer: "981554242",
          landkode: "NO",
          er_omfattet_av_fritaksmetoden: true,
          antall_andeler: 42,
          utbytte: 1_200,
          gevinst_ved_realisasjon_av_andel_i_aksjedel: 500
        }
      ]

      xml =
        SkattemeldingXml.generer_skattemelding_xml(
          sample_regnskap(),
          %SkattemeldingKonfig{underskudd_til_fremfoering: 13_266},
          aksjespesifikasjon: holdings
        )

      assert_xml_valid!(xml, "#{@xsd_dir}/skattemeldingUpersonlig_v5_ekstern.xsd")
    end

    @tag :xsd
    test "naeringsspesifikasjon (v6) with permanent_forskjeller validates" do
      forskjeller = [
        %{type: :tilbakefoeringAvInntektsfoertUtbytte, beloep: 50_429},
        %{type: :skattepliktigDelAvUtbytterOgUtdelinger, beloep: 1_513},
        %{type: :regnskapsmessigGevinstVedRealisasjonAvFinansielleInstrumenter, beloep: 71}
      ]

      xml =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(),
          permanent_forskjeller: forskjeller
        )

      assert_xml_valid!(xml, "#{@xsd_dir}/naeringsspesifikasjon_v6_ekstern.xsd")
    end

    defp assert_xml_valid!(xml, schema_path) do
      unless File.exists?(schema_path), do: flunk("Schema not found: #{schema_path}")

      path =
        Path.join(System.tmp_dir!(), "wenche_xsd_test_#{System.unique_integer([:positive])}.xml")

      File.write!(path, xml)

      {output, status} =
        System.cmd("xmllint", ["--schema", schema_path, path, "--noout"], stderr_to_stdout: true)

      File.rm(path)

      unless status == 0 do
        flunk("XSD validation failed for #{schema_path}:\n#{output}\n\nXML:\n#{xml}")
      end
    end
  end
end
