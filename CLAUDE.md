# Flark — project notes

## Localization: every user-facing string must be bilingual (zh-Hans + English)

Flark ships in **Chinese (source) and English**. Source language is `zh-Hans`; translations
live in `Flark/Resources/Localizable.xcstrings` (and `InfoPlist.xcstrings`), maintained manually.

**Rule: whenever you add or change a user-facing string, provide its English translation too.**
A Chinese literal with no English entry renders as Chinese in the English UI — that is a bug
(e.g. the `可选，留空则用模型名` placeholder once showed Chinese in English mode).

How strings localize:
- `Text("中文")`, `Button("中文")`, `Label("中文", …)`, and `TextField`/`SecureField` placeholders
  are `LocalizedStringKey` and localize automatically **only if** the key exists in the catalog.
- Plain-`String` contexts do **not** auto-localize — wrap them in `String(localized: "中文")`.
  This includes `.navigationTitle(someString)`, `.help("…")`, string interpolation, and titles for
  `confirmationDialog` / `alert`, plus any `String` returned from a model/helper (e.g. an enum
  `label` or a computed display string).
- After adding a string, add a matching entry to `Localizable.xcstrings` with an `en` translation
  (`"state": "translated"`).

When building a new feature, budget for both languages from the start — never leave English untranslated.

## Releasing to TestFlight

Use `scripts/testflight.sh` (XcodeGen regenerates the project, archives Release, uploads via the
App Store Connect API). It needs four env vars, all of which live in a **gitignored** credentials
file outside the repo:

```
~/.appstoreconnect/lifly-release.env     # mode 0600, intentionally outside git
~/.appstoreconnect/private_keys/AuthKey_RJ8CVYBHRY.p8
```

That env file exports `LIFLY_TEAM_ID` (Apple Team ID `CZ4QGMPL9S`), `ASC_KEY_ID`, and
`ASC_ISSUER_ID`. To release (don't paste these into chat or commit them):

```
set -a; source ~/.appstoreconnect/lifly-release.env; set +a
DEVELOPMENT_TEAM="$LIFLY_TEAM_ID" \
ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8" \
./scripts/testflight.sh
```

Bundle id `app.flark.bogota`. Build number auto-set to `YYYYMMDDHHMM` (UTC); keep that 12-digit
format so TestFlight orders builds correctly.

> Swift package dependencies are declared in `project.yml`. Because `testflight.sh` runs
> `xcodegen generate` first, any new SPM dependency MUST be added to `project.yml` (not just the
> `.xcodeproj`) or it gets dropped from the release build.
