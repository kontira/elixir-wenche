# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - unreleased

### Added

- **Skattemelding XML submission to Skatteetaten.** New `Wenche.SkattemeldingXml`
  generates `skattemeldingUpersonlig` (v5), `naeringsspesifikasjon` (v6), and the
  `skattemeldingOgNaeringsspesifikasjonRequest` (v2) envelope against the official
  Skatteetaten XSDs (vendored in `priv/xsd/`). New `Wenche.SkdSkattemeldingClient`
  talks directly to the SKD REST API (pre-filled draft fetch, validation), and
  `Wenche.Skattemelding.valider/2` and `send_inn/2` orchestrate the full Altinn 3
  submission flow including real `partsnummer` fetch and
  `dokumentreferanseTilGjeldendeDokument` chaining.
- **MVA-melding (VAT return) submission.** New `Wenche.MvaMelding` and
  `Wenche.MvaMeldingXml` for bi-monthly VAT returns via Altinn 3. The MVA scope
  is opt-in via `Wenche.Systembruker.rights([:mva_melding])`. Marked experimental.
- `Wenche.Skattemelding.beregn/2` for structured tax-return data and
  `parse_etter_beregning/1` for parsing SKD's beregningsrespons.
- `Wenche.Skattemelding.beregn/2` honors `:permanent_forskjeller` on
  `SkattemeldingKonfig`, bypassing the global `eierandel_datterselskap` heuristic
  when an explicit list is supplied.
- `:permanent_forskjeller` accepts `Decimal` `:beloep` for round-once cumulative
  semantics; integer is still accepted for backwards compatibility.
- `:sum_override` field on all balance-sheet structs (`Anleggsmidler`,
  `Omloepmidler`, `Eiendeler`, `Egenkapital`, `LangsiktigGjeld`, `KortsiktigGjeld`,
  `EgenkapitalOgGjeld`) — lets callers that round once from decimal source data
  pin the grand total without mutating child line values.
- Configurable systembruker scopes via `:features` option; skattemelding and
  mva_melding scopes are opt-in (revisor/regnskapsfører authorization required).
- `Wenche.Systembruker.slett_system/3` for deleting a registered system.
- Configurable `systemNavn` on `BrgXml.generer_hovedskjema`.
- `:opprettet_av` option on skattemelding XML generators.
- `:req_options` support on all HTTP client modules for custom `Req` config.
- Aksjespesifikasjon forwarding through `send_inn/2` and `valider/2`, including
  `<spesifikasjonAvForholdRelevanteForBeskatning>` and
  `<forskjellMellomRegnskapsmessigOgSkattemessigVerdi>` emission.
- Optional `<kontaktperson>` on `<virksomhet>`.
- `Wenche.Maskinporten.get_skd_skattemelding_token/2` for direct SKD validation
  without Altinn exchange.

### Changed

- **3 % addback in `skattepliktigDelAvUtbytterOgUtdelinger` now floors** instead
  of `:half_up` rounding, per skatteloven § 2-38 (6) and the SKD veiledning
  convention used by reference implementations (Fiken).
- Skattemelding XML rewritten against Skatteetaten XSDs (was a best-effort
  emission in 0.1.x).
- BRG XML `underskjema` is now strict-XSD-valid; validation tests added.
- `forekomst <id>` set to the kodeliste kode (was a generated index).
- `aksjeklasse` is lowercased to match SKD's case-sensitive kodeliste.
- Unknown `:aksjespesifikasjon :type` values now raise instead of being silently
  dropped.
- Skattemelding Maskinporten scope now also includes Altinn instance scopes.
- Reduced cyclomatic complexity and nesting depth across three modules; Credo
  strict cleanup.

### Fixed

- BRG XML `orid` values rejected by Brønnøysundregistrene validation.
- `406` from SKD `valider` by accepting XML responses; added
  `charset=UTF-8` to `valider` content-type.
- Altinn 3 app slug for skattemelding submission.
- Wrong MVA-melding resource ID in system user rights.
- `EgenkapitalOgGjeld.sum/1` is now honored by `sumEgenkapitalGjeld` in BRG XML
  (was inlining child sums and ignoring `:sum_override`).

### Removed

- **`Wenche.Skattemelding.generer/2`** — the human-readable text-summary
  renderer (and its ~250 lines of private formatting helpers). Application
  consumers should use `beregn/2`, which returns the same data as a
  structured map suitable for any rendering target. The original Python
  CLI tool emitted a fixed text report; in the Elixir library this concern
  belongs to the caller.
- The short-lived `:permanent_forskjell_total` override on `SkattemeldingKonfig`
  (introduced and removed within this release cycle; superseded by accepting
  `Decimal` `:beloep` in the per-line breakdown).

## [0.1.1] - 2026-03-19

### Fixed

- Corrected GitHub repository URL in package metadata

## [0.1.0] - 2026-03-19

Initial release. This is an Elixir port of [Wenche](https://github.com/olefredrik/Wenche) (Python).

### Added

- Maskinporten authentication with JWT token generation
- Altinn 3 API client for instance management and form submission
- System user registration and rights management
- Annual accounts (årsregnskap) submission to BRG
  - BRG XML generation
  - Inline XBRL (iXBRL) generation
  - Notes (noter) for small enterprises
- Tax calculation (skattemelding) for RF-1028/RF-1167
  - Standard corporate tax calculation
  - Participation exemption (fritaksmetoden)
- Shareholder register (aksjonærregister) for RF-1086
  - SKD REST API client
  - Support for personal and company shareholders
