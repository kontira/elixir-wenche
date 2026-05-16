defmodule Wenche.BrgXmlTest do
  use ExUnit.Case, async: true

  alias Wenche.BrgXml

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

  def sample_regnskap do
    %Aarsregnskap{
      selskap: %Selskap{
        navn: "Test AS",
        org_nummer: "912345678",
        daglig_leder: "Ola Nordmann",
        styreleder: "Kari Nordmann",
        forretningsadresse: "Storgata 1, 0001 Oslo",
        stiftelsesaar: 2020,
        aksjekapital: 30_000
      },
      regnskapsaar: 2025,
      resultatregnskap: %Resultatregnskap{
        driftsinntekter: %Driftsinntekter{salgsinntekter: 500_000, andre_driftsinntekter: 0},
        driftskostnader: %Driftskostnader{
          loennskostnader: 200_000,
          avskrivninger: 50_000,
          andre_driftskostnader: 100_000
        },
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
          egenkapital: %Egenkapital{
            aksjekapital: 100_000,
            overkursfond: 0,
            annen_egenkapital: 150_000
          },
          langsiktig_gjeld: %LangsiktigGjeld{laan_fra_aksjonaer: 100_000},
          kortsiktig_gjeld: %KortsiktigGjeld{leverandoergjeld: 150_000}
        }
      }
    }
  end

  describe "generer_hovedskjema/1" do
    test "generates XML with correct structure" do
      xml = BrgXml.generer_hovedskjema(sample_regnskap())

      assert xml =~ "dataFormatId=\"1266\""
      assert xml =~ "912345678"
      assert xml =~ "Test AS"
      assert xml =~ "2025"
    end

    test "includes regnskapsperiode" do
      xml = BrgXml.generer_hovedskjema(sample_regnskap())

      assert xml =~ "<regnskapsaar orid=\"17102\">2025</regnskapsaar>"
      assert xml =~ "<regnskapsstart orid=\"17103\">2025-01-01</regnskapsstart>"
      assert xml =~ "<regnskapsslutt orid=\"17104\">2025-12-31</regnskapsslutt>"
    end

    test "includes default system name" do
      xml = BrgXml.generer_hovedskjema(sample_regnskap())

      assert xml =~ "<systemNavn orid=\"39007\">Wenche</systemNavn>"
    end

    test "uses custom system name when provided" do
      xml = BrgXml.generer_hovedskjema(sample_regnskap(), system_navn: "Kontira")

      assert xml =~ "<systemNavn orid=\"39007\">Kontira</systemNavn>"
      refute xml =~ ">Wenche<"
    end
  end

  describe "generer_underskjema/1" do
    test "generates XML with correct structure" do
      xml = BrgXml.generer_underskjema(sample_regnskap())

      assert xml =~ "dataFormatId=\"758\""
      assert xml =~ "resultatregnskapDriftsresultat"
      assert xml =~ "balanseAnleggsmidlerOmloepsmidler"
      assert xml =~ "balanseEgenkapitalGjeld"
    end

    test "underskjema XML has balanced open/close tags" do
      xml = BrgXml.generer_underskjema(sample_regnskap())

      # Extract all tags: {:open, name} or {:close, name} (ignoring self-closing, xml decl, comments)
      tags =
        Regex.scan(~r/<(\/?)([a-zA-Z][\w-]*)[^>]*?>/, xml)
        |> Enum.map(fn
          [_, "", name] -> {:open, name}
          [_, "/", name] -> {:close, name}
        end)

      # Walk tags with a stack — every close must match the most recent open
      result =
        Enum.reduce_while(tags, [], fn
          {:open, name}, stack ->
            {:cont, [name | stack]}

          {:close, name}, [name | rest] ->
            {:cont, rest}

          {:close, name}, stack ->
            {:halt, {:mismatch, name, stack}}
        end)

      case result do
        [] ->
          assert true

        {:mismatch, name, stack} ->
          flunk(
            "Closing </#{name}> does not match open tag stack: #{inspect(Enum.take(stack, 3))}"
          )

        remaining ->
          flunk("Unclosed tags remaining: #{inspect(remaining)}")
      end
    end

    test "includes driftsinntekter" do
      xml = BrgXml.generer_underskjema(sample_regnskap())

      assert xml =~ "500000"
      assert xml =~ "salgsinntekt"
    end

    test "includes driftskostnader" do
      xml = BrgXml.generer_underskjema(sample_regnskap())

      assert xml =~ "loennskostnad"
      assert xml =~ "200000"
    end

    test "includes balance figures" do
      xml = BrgXml.generer_underskjema(sample_regnskap())

      # Sum eiendeler (200000 + 300000)
      assert xml =~ "500000"
      # Aksjekapital
      assert xml =~ "100000"
    end

    test "calculates driftsresultat correctly" do
      xml = BrgXml.generer_underskjema(sample_regnskap())

      # Driftsresultat = 500000 - (200000 + 50000 + 100000) = 150000
      assert xml =~ "<aarets orid=\"146\">150000</aarets>"
    end

    test "includes noter section with antallAarsverk" do
      xml = BrgXml.generer_underskjema(sample_regnskap())

      assert xml =~ "<noter>"
      assert xml =~ "</noter>"
      assert xml =~ "<antallAarsverk orid=\"37467\">0</antallAarsverk>"
    end

    test "includes noter with custom antall_ansatte" do
      regnskap = %{sample_regnskap() | noter: %Wenche.Models.Noter{antall_ansatte: 2}}
      xml = BrgXml.generer_underskjema(regnskap)

      assert xml =~ "<antallAarsverk orid=\"37467\">2</antallAarsverk>"
    end

    test "includes egenkapital note in noter when prior year exists" do
      regnskap = %{
        sample_regnskap()
        | foregaaende_aar_balanse: %Balanse{
            eiendeler: %Eiendeler{
              anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 200_000},
              omloepmidler: %Omloepmidler{bankinnskudd: 200_000}
            },
            egenkapital_og_gjeld: %EgenkapitalOgGjeld{
              egenkapital: %Egenkapital{
                aksjekapital: 100_000,
                overkursfond: 0,
                annen_egenkapital: 50_000
              },
              langsiktig_gjeld: %LangsiktigGjeld{laan_fra_aksjonaer: 100_000},
              kortsiktig_gjeld: %KortsiktigGjeld{leverandoergjeld: 150_000}
            }
          }
      }

      xml = BrgXml.generer_underskjema(regnskap)

      assert xml =~ "<noteEgenkapital>"
      assert xml =~ "<egenkapitalAapningsbalanse>"
      assert xml =~ "<egenkapitalAvslutningsbalanse>"
    end

    test "sumEgenkapitalGjeld honors sum_override on EgenkapitalOgGjeld" do
      # Real-world case: a -1 kr supplier-overpayment liability makes
      # raw EK (60_395) + raw gjeld (-1) = 60_394, which does not equal
      # sum_eiendeler (60_395). Setting sum_override on the parent forces
      # the grand total to the rounded-once eiendeler figure so the
      # balance sheet stays self-consistent.
      regnskap = %{
        sample_regnskap()
        | balanse: %Balanse{
            eiendeler: %Eiendeler{
              anleggsmidler: %Anleggsmidler{andre_aksjer: 4_800, sum_override: 4_800},
              omloepmidler: %Omloepmidler{bankinnskudd: 55_595, sum_override: 55_595},
              sum_override: 60_395
            },
            egenkapital_og_gjeld: %EgenkapitalOgGjeld{
              egenkapital: %Egenkapital{
                aksjekapital: 30_000,
                annen_egenkapital: 30_395,
                sum_override: 60_395
              },
              langsiktig_gjeld: %LangsiktigGjeld{sum_override: 0},
              kortsiktig_gjeld: %KortsiktigGjeld{leverandoergjeld: -1, sum_override: -1},
              sum_override: 60_395
            }
          }
      }

      xml = BrgXml.generer_underskjema(regnskap)

      assert xml =~ ~s(<aarets orid="251">60395</aarets>)
      refute xml =~ ~s(<aarets orid="251">60394</aarets>)
    end
  end

  describe "altinnRowId is NOT emitted" do
    test "hovedskjema has no altinnRowId attribute" do
      xml = BrgXml.generer_hovedskjema(sample_regnskap())
      refute xml =~ "altinnRowId"
    end

    test "underskjema has no altinnRowId attribute" do
      xml = BrgXml.generer_underskjema(sample_regnskap())
      refute xml =~ "altinnRowId"
    end
  end

  describe "XSD validation (requires xmllint)" do
    # XSDs are shipped in priv/xsd/brreg/RR-0002 — source is brreg/docs on
    # github (Brønnøysundregistrene's public dokumentasjon repo). No external
    # mounts needed; xmllint is the only environmental dependency.
    @xsd_dir Path.expand("../../priv/xsd/brreg/RR-0002", __DIR__)

    @tag :xsd
    test "hovedskjema validates against RR-0002 (1266) XSD" do
      xml = BrgXml.generer_hovedskjema(sample_regnskap(), system_navn: "Wenche-Test")
      assert_xml_valid!(xml, "#{@xsd_dir}/RR-0002_1266-51820.xsd")
    end

    @tag :xsd
    test "underskjema validates against RR-0002 underskjema (758) XSD" do
      xml = BrgXml.generer_underskjema(sample_regnskap())
      assert_xml_valid!(xml, "#{@xsd_dir}/RR-0002-U_758-51980.xsd")
    end

    # Known limitation: when foregaaende_aar_* are populated, BrgXml emits a
    # <noteEgenkapital> element (rskl. § 7-2b equity reconciliation) that the
    # strict XSD does not define under <noter>. Valid note children per
    # RR-0002-U_758-51980.xsd are: noteLaanLedendePerson, noteTilknyttetSelskap,
    # noteSpesifiseringResultatregnskap, noteEkstraordnaereInntekterKostnader,
    # noteKundefordringer, noteGjeld, noteFinansielleInstrumenter,
    # noteAnleggsmidlerDriftsmidler, noteNummerUtenforMinimumskravSmaaForetak,
    # noteYtterligereOpplysninger.
    # BRG's live validator silently accepts <noteEgenkapital>; strict XSD does
    # not. Fixing requires moving the equity reconciliation into
    # <noteYtterligereOpplysninger> as free text. Not addressed here.

    @tag :xsd
    test "underskjema validates with negative annen_egenkapital (udekket tap)" do
      regnskap = %{
        sample_regnskap()
        | balanse: %{
            sample_regnskap().balanse
            | egenkapital_og_gjeld: %{
                sample_regnskap().balanse.egenkapital_og_gjeld
                | egenkapital: %Egenkapital{
                    aksjekapital: 100_000,
                    overkursfond: 0,
                    annen_egenkapital: -25_000
                  }
              }
          }
      }

      xml = BrgXml.generer_underskjema(regnskap)
      assert_xml_valid!(xml, "#{@xsd_dir}/RR-0002-U_758-51980.xsd")
    end

    @tag :xsd
    test "underskjema validates with negative kortsiktig gjeld (rounding artifact)" do
      regnskap = %{
        sample_regnskap()
        | balanse: %{
            sample_regnskap().balanse
            | egenkapital_og_gjeld: %{
                sample_regnskap().balanse.egenkapital_og_gjeld
                | kortsiktig_gjeld: %KortsiktigGjeld{annen_kortsiktig_gjeld: -1}
              }
          }
      }

      xml = BrgXml.generer_underskjema(regnskap)
      assert_xml_valid!(xml, "#{@xsd_dir}/RR-0002-U_758-51980.xsd")
    end

    defp assert_xml_valid!(xml, schema_path) do
      unless File.exists?(schema_path), do: flunk("Schema not found: #{schema_path}")

      path =
        Path.join(System.tmp_dir!(), "brg_xsd_test_#{System.unique_integer([:positive])}.xml")

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
