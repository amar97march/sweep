# Contributing to Sweep

Thanks for helping! Sweep runs with Full Disk Access and removes files, so a few rules matter more here than
in most projects.

## Reporting a bug

Open an issue with your macOS version, your Mac (Apple silicon or Intel), what you did, what you expected and
what happened. Screenshots help. If a file was removed that shouldn't have been, say which module and which
category it was listed under, and include the action log (Done screen → View Log).

## Suggesting a feature

Open an issue that describes the problem first and your idea second. Features that run quietly on the Mac,
explain themselves and never surprise people fit Sweep best.

## Pull requests

1. Fork the repo and create a branch.
2. `swift test` must pass, and new behaviour needs tests.
3. For UI changes, run `SIZES=1280x820 STEPS=<module> scripts/snapshots.sh` and attach before/after
   screenshots from `.build/snapshots/`.
4. Keep the pull request about one thing.

## The rules

- **Nothing is removed without review.** Every new kind of item goes through the review screen and the
  removal policies in `SweepCore`. Never add a path that deletes without the user seeing it first.
- **Tests stay inside the project.** Tests and screenshot runs must never read personal data they don't
  need, or change anything outside the build folder. Use the confined remover and the throwaway preferences
  (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)).
- **No tracking.** No analytics, no accounts, no network calls beyond checking for app updates.
- **Write it yourself.** Don't copy code, data, text or artwork from other products. Third-party open-source
  code needs a compatible licence and an entry in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Follow the surrounding style:** plain, specific comments and plain UI text that says what happens.

By contributing, you agree that your contributions are licensed under the project's
[GPL-3.0 licence](LICENSE).
