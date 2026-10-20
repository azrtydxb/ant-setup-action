# ant-setup-action

Configures a GitHub Actions job to use a Kuvryn Ant instance for Go
modules, npm/pnpm, cargo, pip/uv and (optionally) `docker login`, authenticated by
exchanging the job's GitHub OIDC token. No stored secrets.

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: actions/checkout@v5
  - uses: azrtydxb/ant-setup-action@v1
    with:
      host: ant.example.com            # your Ant host (see below)
      # docker-login: "true"           # to push to ant.example.com/oci-hosted/...
```

## Which Ant

Set `host` (a host name such as `ant.example.com`) or `ant-url` (a base URL; only its host
is used). The action requests the OIDC token with audience `https://<host>` and sends it to
that host only, so it never guesses a server. Repositories of the `azrtydxb` organization may
omit both: they default to the organization's own deployment, `ant.example.com`. Anywhere else
a missing host is a configuration error: the step warns (or fails with `required: "true"`)
and leaves the public registries in place.

The action does not probe the registry API anonymously. The OIDC exchange itself is the
reachability check, so an Ant whose `/v2/` answers `401` to anonymous clients (the normal
case) works. When it falls back, the warning says why: no `id-token: write` permission, the
host is not reachable, or the exchange was refused (check the trust rules and that the
audience configured in Ant equals `https://<host>`).

What it sets (all via `$GITHUB_ENV`, token masked):

| Tool                               | Configuration                                                                                              |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Go                                 | `GOPROXY=https://ant.example.com/feeds/go/go\|https://proxy.golang.org,direct`, `~/.netrc`, `GOSUMDB` direct |
| npm / pnpm                        | `~/.npmrc` registry + `_authToken`, `NPM_CONFIG_REGISTRY`, `NODE_AUTH_TOKEN`                               |
| cargo                              | `$CARGO_HOME/config.toml` replaces crates.io with the sparse feed, `CARGO_REGISTRIES_ANT_TOKEN`            |
| pip / uv                           | `PIP_INDEX_URL`, `UV_INDEX_URL`, `UV_DEFAULT_INDEX`                                                        |
| Maven (opt-in `maven: "true"`) | `~/.m2/settings.xml`: mirror of `central` to `https://ant.example.com/feeds/maven/maven/`, server `ant` with the exchanged token as password |
| NuGet (opt-in `nuget: "true"`) | user `NuGet.Config`: `https://ant.example.com/feeds/nuget/nuget/v3/index.json` as the only source, with credentials |
| Composer (opt-in `composer: "true"`) | `$COMPOSER_HOME/auth.json` (http-basic) and `config.json` repository `https://ant.example.com/feeds/composer/composer` |
| docker                             | `docker login ant.example.com` when `docker-login: "true"`                                                   |

It also exports `ANT_TOKEN` and `ANT_HOST` for later steps. The token lives for the
trust rule's TTL (1 hour).

When no OIDC token is available (Dependabot, fork PRs, missing `id-token: write`)
or the exchange is refused, the step warns and leaves the public upstream defaults,
unless `required: "true"`.

Maven, NuGet and Composer are opt-in (default `false`); feed slugs are set with `maven-feed`, `nuget-feed` and `composer-feed`. An existing config file not written by this action is kept once as `*.pre-ant`.

Run it in every job that needs it, after `actions/checkout` and inside the job's
`container:` if it has one (files go to that container's `$HOME`). The image needs
`curl`, `wget` or `node` (18+).

## Build caches (opt-in)

`build-cache: "true"` points the job at the Ant **cache feeds** (`buildcache` for buildx layers,
`sccache` for Rust compilation). Same OIDC token, nothing stored.

```yaml
permissions: { id-token: write, contents: read }
steps:
  - uses: actions/checkout@v5
  - uses: docker/setup-buildx-action@v4
  - id: ant
    uses: azrtydxb/ant-setup-action@v1
    with: { build-cache: "true" }
  - uses: docker/build-push-action@v7      # v6 fails on a cache-from ref that does not exist yet
    with:
      push: true
      tags: ...
      cache-from: ${{ steps.ant.outputs.cache-from }}
      cache-to: ${{ steps.ant.outputs.cache-to }}
  - uses: azrtydxb/ant-setup-action/cache-stats@v1   # Rust jobs: sccache hit rate
    if: always()
```

| Input | Default | |
| --- | --- | --- |
| `build-cache` | `false` | Enable everything below. |
| `arch-suffix` | derived (`amd64`, `arm64`) | Architecture part of the tag. |
| `cache-name` | empty | Tag becomes `<branch>-<name>-<arch>`; use per image when a repo builds several. |
| `cache-branch` | PR head branch / ref name / default branch for tags | Branch part of the tag (`/` and other invalid characters become `-`, max 80). |
| `cache-write` | `true` | `false` leaves `cache-to` empty (read-only, e.g. for pull requests that must not write). |
| `sccache` | `auto` | `true`/`false`/`auto` (install when `cargo`, `rustc` or `Cargo.toml` is present). |
| `sccache-version` | `0.17.0` | Installed from the GitHub release, SHA-256 verified, only when `sccache` is not already on PATH. |
| `cache-feed`, `sccache-feed` | `buildcache`, `sccache` | Feed slugs. |

Outputs: `cache-from` (two lines: this branch, then the default branch), `cache-to`
(`mode=max,image-manifest=true,ignore-error=true`), `cache-ref` (`ant.example.com/buildcache/<org>/<repo>`),
`cache-tag`, `sccache`. The same values are exported as `ANT_CACHE_FROM`, `ANT_CACHE_TO`,
`ANT_CACHE_REPO`, `ANT_CACHE_BRANCH`, `ANT_CACHE_DEFAULT_BRANCH` and `ANT_CACHE_ARCH`, so a job
that builds several images can compose
`type=registry,ref=${{ env.ANT_CACHE_REPO }}:${{ env.ANT_CACHE_BRANCH }}-api-${{ env.ANT_CACHE_ARCH }}`.
When Ant is unreachable or no OIDC token exists (fork PRs, Dependabot) the outputs are empty and
the build simply runs without a remote cache.

sccache gets `RUSTC_WRAPPER=sccache`, `CARGO_INCREMENTAL=0`, `SCCACHE_WEBDAV_ENDPOINT`
(`https://ant.example.com/feeds/sccache/raw`), `SCCACHE_WEBDAV_TOKEN` (the short-lived token, written
to `$GITHUB_ENV` like `ANT_TOKEN`) and `SCCACHE_WEBDAV_KEY_PREFIX=<org>/<repo>`. sccache fails soft:
judge it by the `cache-stats` step, not by the build passing.

### cache-stats

`azrtydxb/ant-setup-action/cache-stats` prints `sccache --show-stats`, the job summary, outputs
`hits` and `misses`, and fails below `min-hits` if set. Run it with `if: always()`.

### cache-cleanup

`azrtydxb/ant-setup-action/cache-cleanup` deletes a branch's caches (buildx tags `<repo>:<branch>-*`; sccache
files under `<repo>/<branch>/` if the repo isolates keys per branch), looping while the API answers
`truncated`. Default branch is the one of a `delete` event.

```yaml
on: delete
permissions: { id-token: write }
jobs:
  cleanup:
    if: github.event.ref_type == 'branch'
    runs-on: ubuntu-latest
    steps:
      - uses: azrtydxb/ant-setup-action/cache-cleanup@v1
        with: { host: ant.example.com }
```

The feeds are looked up by slug (`cache-feed`, `sccache-feed`) through `GET /api/v1/feeds?prefix=`,
which works with the scoped CI token. `cache-feed-id` and `sccache-feed-id` exist only as an
optional fallback for a server that cannot list feeds with that token; they have no built-in value.

The cleanup of branch `feat` also removes the caches of `feat-*` branches (the prefix is `feat-`); that
is only a cache.

## Ant side

- GitHub OIDC audience `https://<host>` (Settings, Access, GitHub OIDC; the same host you give the action).
- Trust rules for your organization: for example `refs/heads/main` and `refs/tags/*` map to a service
  principal that can read the language and mirror feeds and publish to `oci-hosted`, and every other ref
  maps to a read-only principal. See the Kuvryn Ant documentation, "GitHub OIDC trust".

## Tests

`sh test/lib_test.sh` runs the unit tests of the exchange and host resolution without a network.
The workflows in `.github/workflows` run the real thing against the azrtydxb deployment.
