defmodule Wenche.MvaMeldingXmlTest do
  use ExUnit.Case, async: true

  alias Wenche.MvaMeldingXml

  def sample_mva_data do
    %{
      org_nummer: "912345678",
      termin: 1,
      year: 2025,
      system_name: "Kontira",
      linjer: [
        %{mva_kode: 3, grunnlag: 1_000_000, sats: 25, merverdiavgift: 250_000},
        %{mva_kode: 31, grunnlag: 200_000, sats: 15, merverdiavgift: 30_000},
        %{mva_kode: 33, grunnlag: 50_000, sats: 12, merverdiavgift: 6_000}
      ],
      fastsatt_merverdiavgift: 286_000
    }
  end

  describe "periode_tekst/1" do
    test "maps termin 1 to januar-februar" do
      assert MvaMeldingXml.periode_tekst(1) == "januar-februar"
    end

    test "maps termin 2 to mars-april" do
      assert MvaMeldingXml.periode_tekst(2) == "mars-april"
    end

    test "maps termin 3 to mai-juni" do
      assert MvaMeldingXml.periode_tekst(3) == "mai-juni"
    end

    test "maps termin 4 to juli-august" do
      assert MvaMeldingXml.periode_tekst(4) == "juli-august"
    end

    test "maps termin 5 to september-oktober" do
      assert MvaMeldingXml.periode_tekst(5) == "september-oktober"
    end

    test "maps termin 6 to november-desember" do
      assert MvaMeldingXml.periode_tekst(6) == "november-desember"
    end

    test "raises for invalid termin" do
      assert_raise FunctionClauseError, fn ->
        MvaMeldingXml.periode_tekst(0)
      end

      assert_raise FunctionClauseError, fn ->
        MvaMeldingXml.periode_tekst(7)
      end
    end
  end

  describe "generer_konvolutt_xml/1" do
    test "produces valid XML with correct root element" do
      xml = MvaMeldingXml.generer_konvolutt_xml(sample_mva_data())

      assert xml =~
               "<mvaMeldingInnsending xmlns=\"no:skatteetaten:fastsetting:avgift:mva:mvameldinginnsending:v1.0\">"

      assert xml =~ "</mvaMeldingInnsending>"
    end

    test "includes organisasjonsnummer" do
      xml = MvaMeldingXml.generer_konvolutt_xml(sample_mva_data())

      assert xml =~ "<organisasjonsnummer>912345678</organisasjonsnummer>"
    end

    test "includes correct period" do
      xml = MvaMeldingXml.generer_konvolutt_xml(sample_mva_data())

      assert xml =~
               "<skattleggingsperiodeToMaaneder>januar-februar</skattleggingsperiodeToMaaneder>"

      assert xml =~ "<aar>2025</aar>"
    end

    test "includes meldingskategori and innsendingstype" do
      xml = MvaMeldingXml.generer_konvolutt_xml(sample_mva_data())

      assert xml =~ "<meldingskategori>alminnelig</meldingskategori>"
      assert xml =~ "<innsendingstype>komplett</innsendingstype>"
      assert xml =~ "<instansstatus>default</instansstatus>"
    end

    test "includes system name" do
      xml = MvaMeldingXml.generer_konvolutt_xml(sample_mva_data())

      assert xml =~ "<opprettetAv>Kontira</opprettetAv>"
    end

    test "includes vedlegg section" do
      xml = MvaMeldingXml.generer_konvolutt_xml(sample_mva_data())

      assert xml =~ "<vedlegg>"
      assert xml =~ "<vedleggstype>mva-melding</vedleggstype>"
      assert xml =~ "<kildegruppe>sluttbrukersystem</kildegruppe>"
      assert xml =~ "<filnavn>melding_xml</filnavn>"
      assert xml =~ "<filekstensjon>xml</filekstensjon>"
      assert xml =~ "<filinnhold>MVA-melding</filinnhold>"
    end

    test "uses different period for termin 4" do
      data = %{sample_mva_data() | termin: 4}
      xml = MvaMeldingXml.generer_konvolutt_xml(data)

      assert xml =~ "<skattleggingsperiodeToMaaneder>juli-august</skattleggingsperiodeToMaaneder>"
    end

    test "uses custom system name" do
      data = %{sample_mva_data() | system_name: "MittSystem"}
      xml = MvaMeldingXml.generer_konvolutt_xml(data)

      assert xml =~ "<opprettetAv>MittSystem</opprettetAv>"
    end
  end

  describe "generer_melding_xml/1" do
    test "produces valid XML with correct namespace" do
      xml = MvaMeldingXml.generer_melding_xml(sample_mva_data())

      assert xml =~
               ~s(xmlns="no:skatteetaten:fastsetting:avgift:mva:skattemeldingformerverdiavgift:v1.0")

      assert xml =~ "<mvaMeldingDto"
      assert xml =~ "</mvaMeldingDto>"
    end

    test "includes innsending with regnskapssystem" do
      xml = MvaMeldingXml.generer_melding_xml(sample_mva_data())

      assert xml =~ "<innsending>"
      assert xml =~ "<regnskapssystemsreferanse>"
      assert xml =~ "<systemnavn>Kontira</systemnavn>"
      assert xml =~ "<systemversjon>1.0</systemversjon>"
    end

    test "includes skattleggingsperiode" do
      xml = MvaMeldingXml.generer_melding_xml(sample_mva_data())

      assert xml =~
               "<skattleggingsperiodeToMaaneder>januar-februar</skattleggingsperiodeToMaaneder>"

      assert xml =~ "<aar>2025</aar>"
    end

    test "includes fastsattMerverdiavgift" do
      xml = MvaMeldingXml.generer_melding_xml(sample_mva_data())

      assert xml =~ "<fastsattMerverdiavgift>286000</fastsattMerverdiavgift>"
    end

    test "includes all mvaSpesifikasjonslinje entries" do
      xml = MvaMeldingXml.generer_melding_xml(sample_mva_data())

      assert xml =~ "<mvaKode>3</mvaKode>"
      assert xml =~ "<grunnlag>1000000</grunnlag>"
      assert xml =~ "<sats>25</sats>"
      assert xml =~ "<merverdiavgift>250000</merverdiavgift>"

      assert xml =~ "<mvaKode>31</mvaKode>"
      assert xml =~ "<grunnlag>200000</grunnlag>"
      assert xml =~ "<sats>15</sats>"
      assert xml =~ "<merverdiavgift>30000</merverdiavgift>"

      assert xml =~ "<mvaKode>33</mvaKode>"
      assert xml =~ "<grunnlag>50000</grunnlag>"
      assert xml =~ "<sats>12</sats>"
      assert xml =~ "<merverdiavgift>6000</merverdiavgift>"
    end

    test "includes skattepliktig organisasjonsnummer" do
      xml = MvaMeldingXml.generer_melding_xml(sample_mva_data())

      assert xml =~
               "<skattepliktig><organisasjonsnummer>912345678</organisasjonsnummer></skattepliktig>"
    end

    test "includes meldingskategori" do
      xml = MvaMeldingXml.generer_melding_xml(sample_mva_data())

      assert xml =~ "<meldingskategori>alminnelig</meldingskategori>"
    end

    test "generates default reference when not provided" do
      xml = MvaMeldingXml.generer_melding_xml(sample_mva_data())

      assert xml =~ "<regnskapssystemsreferanse>mva-912345678-2025-1</regnskapssystemsreferanse>"
    end

    test "uses custom reference when provided" do
      data = Map.put(sample_mva_data(), :referanse, "custom-ref-123")
      xml = MvaMeldingXml.generer_melding_xml(data)

      assert xml =~ "<regnskapssystemsreferanse>custom-ref-123</regnskapssystemsreferanse>"
    end

    test "handles negative fastsatt_merverdiavgift (refund)" do
      data = %{sample_mva_data() | fastsatt_merverdiavgift: -50_000}
      xml = MvaMeldingXml.generer_melding_xml(data)

      assert xml =~ "<fastsattMerverdiavgift>-50000</fastsattMerverdiavgift>"
    end

    test "handles empty linjer list" do
      data = %{sample_mva_data() | linjer: [], fastsatt_merverdiavgift: 0}
      xml = MvaMeldingXml.generer_melding_xml(data)

      assert xml =~ "<fastsattMerverdiavgift>0</fastsattMerverdiavgift>"
      refute xml =~ "<mvaSpesifikasjonslinje>"
    end
  end

  describe "annual filing (filing_frequency: :annual)" do
    def annual_mva_data do
      Map.put(sample_mva_data(), :filing_frequency, :annual)
    end

    test "periode_element/1 emits skattleggingsperiodeAar for annual" do
      assert MvaMeldingXml.periode_element(annual_mva_data()) ==
               "<skattleggingsperiodeAar>aarlig</skattleggingsperiodeAar>"
    end

    test "periode_element/1 defaults to bimonthly when filing_frequency is missing" do
      assert MvaMeldingXml.periode_element(sample_mva_data()) ==
               "<skattleggingsperiodeToMaaneder>januar-februar</skattleggingsperiodeToMaaneder>"
    end

    test "konvolutt uses skattleggingsperiodeAar for annual" do
      xml = MvaMeldingXml.generer_konvolutt_xml(annual_mva_data())

      assert xml =~ "<skattleggingsperiodeAar>aarlig</skattleggingsperiodeAar>"
      refute xml =~ "skattleggingsperiodeToMaaneder"
    end

    test "melding uses skattleggingsperiodeAar for annual" do
      xml = MvaMeldingXml.generer_melding_xml(annual_mva_data())

      assert xml =~ "<skattleggingsperiodeAar>aarlig</skattleggingsperiodeAar>"
      refute xml =~ "skattleggingsperiodeToMaaneder"
    end

    test "melding generates 'aarlig' suffix in default reference for annual" do
      xml = MvaMeldingXml.generer_melding_xml(annual_mva_data())

      assert xml =~
               "<regnskapssystemsreferanse>mva-912345678-2025-aarlig</regnskapssystemsreferanse>"
    end
  end

  describe "XSD validation (requires xmllint; XSDs vendored at priv/xsd/skatteetaten/mva)" do
    @xsd_dir Path.join(:code.priv_dir(:wenche), "xsd/skatteetaten/mva")
    @konvolutt_xsd "#{@xsd_dir}/no.skatteetaten.fastsetting.avgift.mva.mvameldinginnsending.v1.0.xsd"
    @melding_xsd "#{@xsd_dir}/no.skatteetaten.fastsetting.avgift.mva.skattemeldingformerverdiavgift.v1.0.xsd"

    @tag :xsd
    test "konvolutt (mvameldinginnsending v1.0) validates" do
      xml = MvaMeldingXml.generer_konvolutt_xml(sample_mva_data())
      assert_xml_valid!(xml, @konvolutt_xsd)
    end

    @tag :xsd
    test "melding (skattemeldingformerverdiavgift v1.0) validates" do
      xml = MvaMeldingXml.generer_melding_xml(sample_mva_data())
      assert_xml_valid!(xml, @melding_xsd)
    end

    @tag :xsd
    test "melding with negative fastsatt_merverdiavgift (refund) validates" do
      data = %{sample_mva_data() | fastsatt_merverdiavgift: -50_000}
      xml = MvaMeldingXml.generer_melding_xml(data)
      assert_xml_valid!(xml, @melding_xsd)
    end

    @tag :xsd
    test "melding with empty linjer validates" do
      data = %{sample_mva_data() | linjer: [], fastsatt_merverdiavgift: 0}
      xml = MvaMeldingXml.generer_melding_xml(data)
      assert_xml_valid!(xml, @melding_xsd)
    end

    @tag :xsd
    test "konvolutt validates for every termin 1..6" do
      for termin <- 1..6 do
        xml = MvaMeldingXml.generer_konvolutt_xml(%{sample_mva_data() | termin: termin})
        assert_xml_valid!(xml, @konvolutt_xsd)
      end
    end

    @tag :xsd
    test "konvolutt validates for annual filing_frequency" do
      data = Map.put(sample_mva_data(), :filing_frequency, :annual)
      xml = MvaMeldingXml.generer_konvolutt_xml(data)
      assert_xml_valid!(xml, @konvolutt_xsd)
    end

    @tag :xsd
    test "melding validates for annual filing_frequency" do
      data = Map.put(sample_mva_data(), :filing_frequency, :annual)
      xml = MvaMeldingXml.generer_melding_xml(data)
      assert_xml_valid!(xml, @melding_xsd)
    end

    defp assert_xml_valid!(xml, schema_path) do
      unless File.exists?(schema_path), do: flunk("Schema not found: #{schema_path}")

      path =
        Path.join(
          System.tmp_dir!(),
          "wenche_mva_xsd_test_#{System.unique_integer([:positive])}.xml"
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
