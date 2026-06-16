defmodule Wenche.AarsregnskapTest do
  use ExUnit.Case, async: true

  alias Wenche.Aarsregnskap

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
    Noter,
    Omloepmidler,
    Resultatregnskap,
    Selskap
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
        driftsinntekter: %Driftsinntekter{salgsinntekter: 0, andre_driftsinntekter: 0},
        driftskostnader: %Driftskostnader{andre_driftskostnader: 5_000},
        finansposter: %Finansposter{
          utbytte_fra_datterselskap: 100_000,
          andre_finansinntekter: 500
        }
      },
      balanse: %Balanse{
        eiendeler: %Eiendeler{
          anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 500_000},
          omloepmidler: %Omloepmidler{bankinnskudd: 125_500}
        },
        egenkapital_og_gjeld: %EgenkapitalOgGjeld{
          egenkapital: %Egenkapital{aksjekapital: 30_000, annen_egenkapital: 595_500},
          langsiktig_gjeld: %LangsiktigGjeld{},
          kortsiktig_gjeld: %KortsiktigGjeld{}
        }
      }
    }
  end

  describe "valider/1" do
    test "returns empty list for valid regnskap" do
      regnskap = sample_regnskap()
      assert Wenche.Aarsregnskap.valider(regnskap) == []
    end

    test "returns error when balance doesn't balance" do
      regnskap = %{
        sample_regnskap()
        | balanse: %Balanse{
            eiendeler: %Eiendeler{
              anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 600_000},
              omloepmidler: %Omloepmidler{bankinnskudd: 100_000}
            },
            egenkapital_og_gjeld: %EgenkapitalOgGjeld{
              egenkapital: %Egenkapital{aksjekapital: 30_000, annen_egenkapital: 100_000},
              langsiktig_gjeld: %LangsiktigGjeld{},
              kortsiktig_gjeld: %KortsiktigGjeld{}
            }
          }
      }

      errors = Wenche.Aarsregnskap.valider(regnskap)
      assert length(errors) == 1
      assert hd(errors) =~ "Balansen går ikke opp"
    end

    test "returns error for invalid org_nummer" do
      selskap = %{sample_selskap() | org_nummer: "12345"}
      regnskap = %{sample_regnskap() | selskap: selskap}

      errors = Wenche.Aarsregnskap.valider(regnskap)
      assert Enum.any?(errors, &(&1 =~ "Organisasjonsnummeret må være 9 siffer"))
    end

    test "warns when loennskostnader > 0 but antall_ansatte is 0" do
      regnskap = %{
        sample_regnskap()
        | resultatregnskap: %Resultatregnskap{
            driftskostnader: %Driftskostnader{loennskostnader: 100_000}
          },
          noter: %Noter{antall_ansatte: 0}
      }

      # Fix balance to match
      regnskap = %{
        regnskap
        | balanse: %Balanse{
            eiendeler: %Eiendeler{
              anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 500_000},
              omloepmidler: %Omloepmidler{bankinnskudd: 125_500}
            },
            egenkapital_og_gjeld: %EgenkapitalOgGjeld{
              egenkapital: %Egenkapital{aksjekapital: 30_000, annen_egenkapital: 595_500},
              langsiktig_gjeld: %LangsiktigGjeld{},
              kortsiktig_gjeld: %KortsiktigGjeld{}
            }
          }
      }

      errors = Wenche.Aarsregnskap.valider(regnskap)
      assert Enum.any?(errors, &(&1 =~ "Lønnskostnader > 0 men antall ansatte er 0"))
    end

    test "warns when laan_fra_aksjonaer > 0 but no laan_til_naerstaaende in noter" do
      regnskap = %{
        sample_regnskap()
        | balanse: %Balanse{
            eiendeler: %Eiendeler{
              anleggsmidler: %Anleggsmidler{aksjer_i_datterselskap: 500_000},
              omloepmidler: %Omloepmidler{bankinnskudd: 225_500}
            },
            egenkapital_og_gjeld: %EgenkapitalOgGjeld{
              egenkapital: %Egenkapital{aksjekapital: 30_000, annen_egenkapital: 595_500},
              langsiktig_gjeld: %LangsiktigGjeld{laan_fra_aksjonaer: 100_000},
              kortsiktig_gjeld: %KortsiktigGjeld{}
            }
          },
          noter: %Noter{laan_til_naerstaaende: []}
      }

      errors = Wenche.Aarsregnskap.valider(regnskap)
      assert Enum.any?(errors, &(&1 =~ "Lån fra aksjonær"))
    end
  end

  describe "les_config/1" do
    test "parses a minimal config.yaml into Aarsregnskap struct" do
      yaml = """
      selskap:
        navn: "Testfirma AS"
        org_nummer: 999888777
        daglig_leder: "Test Testesen"
        styreleder: "Styre Styresen"
        forretningsadresse: "Testveien 1, 0001 Oslo"
        stiftelsesaar: 2021
        aksjekapital: 30000
      regnskapsaar: 2025
      resultatregnskap:
        driftsinntekter:
          salgsinntekter: 100000
          andre_driftsinntekter: 5000
        driftskostnader:
          loennskostnader: 50000
          avskrivninger: 10000
          andre_driftskostnader: 20000
        finansposter:
          utbytte_fra_datterselskap: 0
          andre_finansinntekter: 1000
          rentekostnader: 500
          andre_finanskostnader: 200
      balanse:
        eiendeler:
          anleggsmidler:
            aksjer_i_datterselskap: 0
            andre_aksjer: 10000
            langsiktige_fordringer: 5000
          omloepmidler:
            kortsiktige_fordringer: 15000
            bankinnskudd: 80000
        egenkapital_og_gjeld:
          egenkapital:
            aksjekapital: 30000
            overkursfond: 0
            annen_egenkapital: 50000
          langsiktig_gjeld:
            laan_fra_aksjonaer: 0
            andre_langsiktige_laan: 10000
          kortsiktig_gjeld:
            leverandoergjeld: 5000
            skyldige_offentlige_avgifter: 10000
            annen_kortsiktig_gjeld: 5000
      noter:
        antall_ansatte: 2
      """

      path = Path.join(System.tmp_dir!(), "test_config_#{:rand.uniform(100_000)}.yaml")
      File.write!(path, yaml)

      on_exit(fn -> File.rm(path) end)

      assert {:ok, regnskap} = Wenche.Aarsregnskap.les_config(path)
      assert regnskap.selskap.navn == "Testfirma AS"
      assert regnskap.selskap.org_nummer == "999888777"
      assert regnskap.regnskapsaar == 2025

      # Resultat
      assert regnskap.resultatregnskap.driftsinntekter.salgsinntekter == 100_000
      assert regnskap.resultatregnskap.driftsinntekter.andre_driftsinntekter == 5_000
      assert regnskap.resultatregnskap.driftskostnader.loennskostnader == 50_000
      assert regnskap.resultatregnskap.driftskostnader.avskrivninger == 10_000
      assert regnskap.resultatregnskap.driftskostnader.andre_driftskostnader == 20_000
      assert regnskap.resultatregnskap.finansposter.andre_finansinntekter == 1_000
      assert regnskap.resultatregnskap.finansposter.rentekostnader == 500
      assert regnskap.resultatregnskap.finansposter.andre_finanskostnader == 200

      # Balanse
      assert regnskap.balanse.eiendeler.anleggsmidler.andre_aksjer == 10_000
      assert regnskap.balanse.eiendeler.anleggsmidler.langsiktige_fordringer == 5_000
      assert regnskap.balanse.eiendeler.omloepmidler.kortsiktige_fordringer == 15_000
      assert regnskap.balanse.eiendeler.omloepmidler.bankinnskudd == 80_000
      assert regnskap.balanse.egenkapital_og_gjeld.egenkapital.aksjekapital == 30_000
      assert regnskap.balanse.egenkapital_og_gjeld.egenkapital.annen_egenkapital == 50_000

      assert regnskap.balanse.egenkapital_og_gjeld.langsiktig_gjeld.andre_langsiktige_laan ==
               10_000

      assert regnskap.balanse.egenkapital_og_gjeld.kortsiktig_gjeld.leverandoergjeld == 5_000

      assert regnskap.balanse.egenkapital_og_gjeld.kortsiktig_gjeld.skyldige_offentlige_avgifter ==
               10_000

      # Noter
      assert regnskap.noter.antall_ansatte == 2
    end
  end

  describe "send_inn/3" do
    @send_opts [plug: {Req.Test, Wenche.AltinnClient.Aarsregnskap}, retry: false]

    test "returns a SubmissionResult carrying the submitted XML and the Altinn response" do
      Req.Test.stub(Wenche.AltinnClient.Aarsregnskap, fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/instances") ->
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "id" => "50012345/abc-123",
              "data" => [
                %{"id" => "h-1", "dataType" => "Hovedskjema"},
                %{"id" => "u-1", "dataType" => "Underskjema"}
              ]
            })

          String.contains?(conn.request_path, "/process/next") ->
            Req.Test.json(conn, %{"ended" => "2025-06-01T10:00:00Z"})

          true ->
            # data element uploads (PUT /data/...)
            Req.Test.json(conn, %{})
        end
      end)

      client = Wenche.AltinnClient.new("test-token", env: "test", req_options: @send_opts)

      assert {:ok, %Wenche.SubmissionResult{} = result} =
               Wenche.Aarsregnskap.send_inn(sample_regnskap(), client)

      assert Enum.map(result.documents, & &1.name) == ["hovedskjema", "underskjema"]
      assert Enum.all?(result.documents, &(is_binary(&1.content) and &1.content =~ "<"))
      assert result.response == %{"ended" => "2025-06-01T10:00:00Z"}
      assert is_binary(result.reference)
    end
  end
end
