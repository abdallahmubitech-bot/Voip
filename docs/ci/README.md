# CI: build the release APK on GitHub runners

`build-apk.yml` in this folder is a ready-made GitHub Actions workflow.

It lives here rather than in `.github/workflows/` only because the token used
for the initial import did not carry the `workflow` scope. To enable it, either:

1. **Web UI** — open the file on GitHub, click *Raw*, then use
   *Add file → Create new file* and save it as `.github/workflows/build-apk.yml`.
2. **Locally** — `mkdir -p .github/workflows && git mv docs/ci/build-apk.yml .github/workflows/`
   and push with a token that has the `workflow` scope.

The workflow installs Temurin 17 + Flutter 3.47.9, runs `flutter analyze` and
`flutter test`, builds `flutter build apk --release --target-platform=android-arm64`
and uploads the APK as an artifact.
