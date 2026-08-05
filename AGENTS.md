# Project Agent Rules

## Packaging after changes

- After completing and verifying each round of project changes, run `./build-app.sh` immediately without waiting for an additional packaging request.
- Verify that both `outputs/SuperScreenshot.app` and the versioned Universal ZIP package were generated successfully.
- Report the packaged version and artifact paths to the user.

## Sparkle appcast releases

- Every newly published version in `appcast.xml` must include a concise changelog of a few sentences.
- Re-sign the appcast after adding or changing release notes, and verify that the committed file exactly matches the generated signed feed.
