# Versioning

melo is `MAJOR.MINOR.PATCH`. Before 1.0:

- **PATCH**: fixes only.
- **MINOR**: features, and any change to the settings or library file formats.
  A MINOR release may break either format without a migration; the CHANGELOG
  says so when it does.
- **MAJOR**: from 1.0, the file formats stop changing.

Alpha N is tagged `alpha-N` and versioned `0.N.0`. A fix to it is tagged
`alpha-N.1` and versioned `0.N.1`. Alpha packages carry that version.

The nightly is built once a day from `main` when `main` has changed since the
last nightly, and replaces it under the `nightly` tag. It is not tested. Its
packages are versioned `<version>+git<YYYYMMDD>.<commit>`, where `<commit>` is
the 7-character commit hash.

## Releasing an alpha

1. Change the version in every file listed below, and add a `<release>` for it
   to `resources/melo.metainfo.xml`. Without it, software centres show the
   previous release.
2. Commit and push, then tag:

   ```
   git tag -a alpha-N -m "Alpha N"
   git push origin alpha-N
   ```

3. CI runs the tests, builds the AppImages (full and lite), the rpm, deb and
   Arch packages and a sources tarball, and attaches them to a draft release.
   If the tests fail, no draft is made. If the tag is not `alpha-N` or
   `alpha-N.P`, or does not match the version in `CMakeLists.txt`, it stops
   with the reason.
4. Install the draft's builds and test them.
5. Publish the draft on the Releases page.

## Where the number lives

Change the version in each of these files:

```
grep -rn "0\.1\.0" CMakeLists.txt scripts/melo.iss \
     sidecar/package.json sidecar/src/main.ts sidecar/src/metadata.ts
```

Replace `0\.1\.0` with the version you are leaving.
