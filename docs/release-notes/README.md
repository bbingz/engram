# Release notes

User-facing notes for GitHub Releases. One file per version:

```text
docs/release-notes/<MAJOR.MINOR.PATCH>.md
```

## Iron rule

Curate the **delta from the last public (shipped) release**, not every commit
since the previous tag. Drop intra-cycle fixes a re-downloader of the previous
public build never saw as a regression. Second person, Highlights before Bug
Fixes. About 10–30 lines.

## Banned wording

Notes must not contain (case-insensitive):

- `internal`
- `implementation`
- `pre-release`
- `validation fix`
- `cleanup`
- `hardened` / `hardening`

These belong in `CHANGELOG.md` (agent narrative), not in the public release body.

## CI

On every `v*` tag, `validate-release-tag` requires a non-empty
`docs/release-notes/${GITHUB_REF_NAME#v}.md` before the build runs.
