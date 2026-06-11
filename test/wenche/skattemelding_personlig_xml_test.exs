defmodule Wenche.SkattemeldingPersonligXmlTest do
  use ExUnit.Case, async: true

  alias Wenche.SkattemeldingPersonligXml
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

  @v13_ns "urn:no:skatteetaten:fastsetting:formueinntekt:skattemelding:ekstern:v13"

  # An ENK (enkeltpersonforetak): the "selskap" carries the owner's sole
  # proprietorship org number; there is no aksjekapital / datterselskap.
  def sample_enk do
    %Selskap{
      navn: "Ola Nordmann ENK",
      org_nummer: "912345678",
      forretningsadresse: "Storgata 1, 0001 Oslo",
      stiftelsesaar: 2022,
      aksjekapital: 0
    }
  end

  def sample_regnskap do
    %Aarsregnskap{
      selskap: sample_enk(),
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
          omloepmidler: %Omloepmidler{
            kortsiktige_fordringer: 20_000,
            bankinnskudd: 130_000
          }
        },
        egenkapital_og_gjeld: %EgenkapitalOgGjeld{
          egenkapital: %Egenkapital{
            aksjekapital: 0,
            overkursfond: 0,
            annen_egenkapital: 120_000
          },
          langsiktig_gjeld: %LangsiktigGjeld{
            laan_fra_aksjonaer: 0,
            andre_langsiktige_laan: 0
          },
          kortsiktig_gjeld: %KortsiktigGjeld{
            leverandoergjeld: 30_000,
            skyldige_offentlige_avgifter: 0,
            annen_kortsiktig_gjeld: 0
          }
        }
      }
    }
  end

  describe "generer_skattemelding_personlig_xml/2" do
    test "produces minimal personlig XML with the v13 namespace" do
      xml = SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap())

      assert xml =~ ~s(xmlns="#{@v13_ns}")
      assert xml =~ "<skattemelding"
      assert xml =~ "</skattemelding>"
    end

    test "emits partsreferanse and inntektsaar" do
      xml = SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap())

      assert xml =~ "<partsreferanse>912345678</partsreferanse>"
      assert xml =~ "<inntektsaar>2025</inntektsaar>"
    end

    test "uses :partsreferanse override when provided" do
      xml =
        SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
          partsreferanse: 4_711
        )

      assert xml =~ "<partsreferanse>4711</partsreferanse>"
      refute xml =~ "<partsreferanse>912345678</partsreferanse>"
    end

    test "does not emit upersonlig-only elements" do
      xml = SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap())

      refute xml =~ "<partsnummer>"
      refute xml =~ "inntektOgUnderskudd"
    end

    test "stays minimal (no naering block) without a carry-forward" do
      xml = SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap())

      refute xml =~ "<naering>"
      refute xml =~ "samordnetPersoninntekt"
    end

    test "stays minimal when the carry-forward is zero or negative" do
      for beloep <- [0, -1] do
        xml =
          SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
            fremfoerbar_negativ_personinntekt: beloep
          )

        refute xml =~ "<naering>"
      end
    end
  end

  describe "fremførbar negativ personinntekt (skatteloven § 12-13)" do
    test "emits the carry-forward at the v13 samordnetPersoninntekt path" do
      xml =
        SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
          fremfoerbar_negativ_personinntekt: 50_000
        )

      assert xml =~ "<naering>"
      assert xml =~ "<naeringsinntektMv>"
      assert xml =~ "<samordnetPersoninntekt>"

      assert xml =~
               ~r{<fremfoerbarNegativPersoninntektFraTidligereAar>\s*<beloep>\s*<beloepSomHeltall>50000</beloepSomHeltall>}
    end

    test "joins to the næringsspesifikasjon via identifikatorForFordeltBeregnetPersoninntekt" do
      # The næringsspesifikasjon mints "1" for the single ENK virksomhet; the
      # personlig skattemelding must reference the same key so SKD can derive
      # fordeltBeregnetPersoninntektFraNaeringsspesifikasjon onto this entry.
      ne =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(),
          skattepliktig_type: :personlig
        )

      assert ne =~
               ~r{<identifikatorForFordeltBeregnetPersoninntekt>\s*<tekst>1</tekst>}

      sm =
        SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
          fremfoerbar_negativ_personinntekt: 50_000
        )

      assert sm =~
               "<identifikatorForFordeltBeregnetPersoninntekt>1</identifikatorForFordeltBeregnetPersoninntekt>"
    end

    test "defaults naeringstype to the annenNaering kodeliste code" do
      xml =
        SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
          fremfoerbar_negativ_personinntekt: 50_000
        )

      assert xml =~ "<naeringstype>annenNaering</naeringstype>"
    end

    test "honours a :naeringstype override" do
      xml =
        SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
          fremfoerbar_negativ_personinntekt: 50_000,
          naeringstype: "fiskeOgFangst"
        )

      assert xml =~ "<naeringstype>fiskeOgFangst</naeringstype>"
      refute xml =~ "annenNaering"
    end

    test "does NOT emit the SKD-derived samordning results (those are erAvledet)" do
      xml =
        SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
          fremfoerbar_negativ_personinntekt: 50_000
        )

      # Only the input field is supplied; Skatteetaten derives the rest.
      refute xml =~ "fordeltBeregnetPersoninntektFraNaeringsspesifikasjon"
      refute xml =~ "personinntektFoerFremfoering"
      refute xml =~ "<personinntekt>"
    end
  end

  # An ENK is not a separate taxpayer, so it has NO AS-style corporate loss
  # carryforward. This documents the two ENK mechanisms and how they map onto
  # the XML, contrasted with the AS (upersonlig) flow.
  describe "ENK vs AS carry-loss-forward semantics" do
    test "AS carries its corporate underskudd via fremfoertUnderskuddFraTidligereAar" do
      # The upersonlig (AS) skattemelding is where a prior-year corporate loss
      # (skatteloven § 14-6) is submitted by the filing system — the ENK flow
      # has no equivalent submitted field.
      as_sm =
        SkattemeldingXml.generer_skattemelding_xml(
          sample_regnskap(),
          %SkattemeldingKonfig{underskudd_til_fremfoering: 80_000}
        )

      assert as_sm =~ "<fremfoertUnderskuddFraTidligereAar>"
      assert as_sm =~ "<beloepSomHeltall>80000</beloepSomHeltall>"
    end

    test "ENK does NOT submit a corporate-style underskudd in the skattemelding" do
      # § 14-6 underskudd til fremføring on the owner's alminnelig inntekt is
      # assessed and pre-filled by Skatteetaten — the ENK shell never carries
      # fremfoertUnderskuddFraTidligereAar.
      enk_sm =
        SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
          fremfoerbar_negativ_personinntekt: 50_000
        )

      refute enk_sm =~ "fremfoertUnderskuddFraTidligereAar"
    end

    test "ENK carries forward negative personinntekt (§ 12-13), AS has no personinntekt" do
      enk_sm =
        SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
          fremfoerbar_negativ_personinntekt: 50_000
        )

      # The ENK-only mechanism: a separate, ring-fenced carryforward on the
      # personinntekt base (foretaksmodellen), which an AS has no analogue for.
      assert enk_sm =~ "fremfoerbarNegativPersoninntektFraTidligereAar"

      as_ne = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())
      refute as_ne =~ "fremfoerbarNegativPersoninntekt"
      refute as_ne =~ "samordnetPersoninntekt"
    end
  end

  describe "naeringsspesifikasjon with skattepliktig_type: :personlig" do
    setup do
      xml =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(),
          skattepliktig_type: :personlig
        )

      %{xml: xml}
    end

    test "uses enkeltpersonforetak / begrensetRegnskapsplikt", %{xml: xml} do
      assert xml =~ "<virksomhetstype>enkeltpersonforetak</virksomhetstype>"
      assert xml =~ "<regnskapspliktstype>begrensetRegnskapsplikt</regnskapspliktstype>"
      refute xml =~ "oevrigSelskap"
      refute xml =~ "fullRegnskapsplikt"
    end

    test "allocates næringsinntekt to the innehaver (personlig fordelt block)", %{xml: xml} do
      assert xml =~ "<fordeltBeregnetNaeringsinntektForPersonligSkattepliktigEllerSdf>"
      refute xml =~ "fordeltBeregnetNaeringsinntektForUpersonligSkattepliktig"
    end

    test "omits the optional regeltypeForAarsregnskap for ENK", %{xml: xml} do
      refute xml =~ "regeltypeForAarsregnskap"
    end
  end

  describe "upersonlig naeringsspesifikasjon stays unchanged (default)" do
    test "still emits oevrigSelskap / upersonlig allocation" do
      xml = SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap())

      assert xml =~ "<virksomhetstype>oevrigSelskap</virksomhetstype>"
      assert xml =~ "<regnskapspliktstype>fullRegnskapsplikt</regnskapspliktstype>"
      assert xml =~ "fordeltBeregnetNaeringsinntektForUpersonligSkattepliktig"
    end
  end

  describe "request envelope with skattemelding_dokumenttype: skattemeldingPersonlig" do
    test "sets the skattemelding dokument type to skattemeldingPersonlig" do
      sm = SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap())

      ne =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(),
          skattepliktig_type: :personlig
        )

      req =
        SkattemeldingXml.generer_request_xml(sm, ne,
          inntektsaar: 2025,
          tin: "912345678",
          skattemelding_dokumenttype: "skattemeldingPersonlig"
        )

      assert req =~ "<type>skattemeldingPersonlig</type>"
      refute req =~ "<type>skattemeldingUpersonlig</type>"
      assert req =~ "<type>naeringsspesifikasjon</type>"
    end

    test "rejects an unknown skattemelding dokument type" do
      assert_raise ArgumentError, ~r/skattemelding_dokumenttype/, fn ->
        SkattemeldingXml.generer_request_xml("<a/>", "<b/>",
          inntektsaar: 2025,
          skattemelding_dokumenttype: "tull"
        )
      end
    end
  end

  describe "hent_partsreferanse/1" do
    test "extracts the integer partsreferanse" do
      xml = SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap())
      assert {:ok, 912_345_678} = SkattemeldingPersonligXml.hent_partsreferanse(xml)
    end

    test "handles namespace-prefixed elements" do
      xml = ~s(<ns:skattemelding><ns:partsreferanse>4711</ns:partsreferanse></ns:skattemelding>)
      assert {:ok, 4_711} = SkattemeldingPersonligXml.hent_partsreferanse(xml)
    end

    test "returns an error when partsreferanse is absent" do
      assert {:error, :partsreferanse_not_found} =
               SkattemeldingPersonligXml.hent_partsreferanse("<skattemelding/>")
    end
  end

  describe "XSD validation (requires xmllint; XSDs vendored at priv/xsd/skatteetaten)" do
    @xsd_dir Path.join(:code.priv_dir(:wenche), "xsd/skatteetaten")

    @tag :xsd
    test "personlig skattemelding (v13) validates" do
      xml = SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap())
      assert_xml_valid!(xml, "#{@xsd_dir}/skattemelding_v13_ekstern.xsd")
    end

    @tag :xsd
    test "personlig skattemelding (v13) with fremførbar negativ personinntekt validates" do
      xml =
        SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap(),
          fremfoerbar_negativ_personinntekt: 50_000
        )

      assert_xml_valid!(xml, "#{@xsd_dir}/skattemelding_v13_ekstern.xsd")
    end

    @tag :xsd
    test "ENK naeringsspesifikasjon (v6, personlig) validates" do
      xml =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(),
          skattepliktig_type: :personlig
        )

      assert_xml_valid!(xml, "#{@xsd_dir}/naeringsspesifikasjon_v6_ekstern.xsd")
    end

    @tag :xsd
    test "personlig request envelope (v2) validates" do
      sm = SkattemeldingPersonligXml.generer_skattemelding_personlig_xml(sample_regnskap())

      ne =
        SkattemeldingXml.generer_naeringsspesifikasjon_xml(sample_regnskap(),
          skattepliktig_type: :personlig
        )

      req =
        SkattemeldingXml.generer_request_xml(sm, ne,
          inntektsaar: 2025,
          tin: "912345678",
          skattemelding_dokumenttype: "skattemeldingPersonlig"
        )

      assert_xml_valid!(req, "#{@xsd_dir}/skattemeldingognaeringsspesifikasjonrequest_v2.xsd")
    end

    defp assert_xml_valid!(xml, schema_path) do
      unless File.exists?(schema_path), do: flunk("Schema not found: #{schema_path}")

      path =
        Path.join(
          System.tmp_dir!(),
          "wenche_personlig_xsd_test_#{System.unique_integer([:positive])}.xml"
        )

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
