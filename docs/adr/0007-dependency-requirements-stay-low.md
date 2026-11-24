# Dependency requirements aren't raised without a reason

Fil is a library, so a requirement in `mix.exs` is the lowest version every app that uses Fil must install, and
`mix.lock` isn't part of the package. Requirements aren't raised unless Fil needs the newer version.

`renovate.json` keeps Renovate to this as far as it can. For a release the requirement allows, Renovate updates only
`mix.lock`. A release outside it, such as a new major version, still gets a PR that raises the requirement, which needs
a review by hand. `~> 0.x` dependencies are left to lock file maintenance, because Renovate reads `~> 0.33` as `< 0.34`
and would raise them for every new 0.x release, as it did on the branch of
[#60](https://github.com/pehbehbeh/fil/pull/60) before that change was reverted. Renovate resolves for the oldest
supported OTP.

## Consequences

- `~> 0.x` dependencies get no PRs of their own with release notes.
- The test jobs in CI use the locked versions. Nothing tests the lowest allowed versions.
