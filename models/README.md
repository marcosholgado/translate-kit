# Test model data

This directory holds the **test-model fixtures** used by the test suites. It is
*not* production data: the published release AAR ships no model assets at all.

These artifacts are **fetched, not committed** (see `scripts/fetch-models.sh`);
the binaries are `.gitignore`d. The directory is kept so the Android
`assets.srcDirs` mapping resolves even before the fetch runs.

| Path | Purpose | Source / License |
|------|---------|------------------|
| `test-models/ende.student.tiny11/` | Tiny en→de student model — native (gtest) + instrumented translation goldens | Bergamot, CC-BY-SA-4.0 (test only) |

## Why nothing ships in the release AAR

- **Language detection** needs no model: CLD2's language profiles are compiled
  into the native library (Apache-2.0).
- **Translation (NMT)** models are downloaded on demand by the consuming app and
  passed to the library as on-disk paths — never bundled.
- **Sentence splitting** runs in `paragraph` mode, so no `nonbreaking_prefixes`
  files are needed.

The Android module therefore maps this directory into the **`debug`** source set
only (see `android/translate-kit/build.gradle`), so the test model reaches
instrumented tests but never the published release AAR.
