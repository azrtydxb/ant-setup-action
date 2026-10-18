# ant-setup-action

Configures a GitHub Actions job to use Kuvryn Ant (`https://ant.azrty.com`) for Go
modules, npm/pnpm, cargo, pip/uv and (optionally) `docker login`, authenticated by
exchanging the job's GitHub OIDC token. No stored secrets.

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: actions/checkout@v5
  - uses: azrtydxb/ant-setup-action@v1
    # with: { docker-login: "true" }   # to push to ant.azrty.com/oci-hosted/...
```

What it sets (all via `$GITHUB_ENV`, token masked):

| Tool       | Configuration                                                                                   |
| ---------- | ----------------------------------------------------------------------------------------------- |
| Go         | `GOPROXY=https://ant.azrty.com/feeds/go/go,direct`, `~/.netrc`, `NETRC`                         |
| npm / pnpm | `~/.npmrc` registry + `_authToken`, `NPM_CONFIG_REGISTRY`, `NODE_AUTH_TOKEN`                    |
| cargo      | `$CARGO_HOME/config.toml` replaces crates.io with the sparse feed, `CARGO_REGISTRIES_ANT_TOKEN` |
| pip / uv   | `PIP_INDEX_URL`, `UV_INDEX_URL`, `UV_DEFAULT_INDEX`                                             |
| docker     | `docker login ant.azrty.com` when `docker-login: "true"`                                        |

It also exports `ANT_TOKEN` and `ANT_HOST` for later steps. The token lives for the
trust rule's TTL (1 hour).

When no OIDC token is available (Dependabot, fork PRs, missing `id-token: write`)
or the exchange is refused, the step warns and leaves the public upstream defaults,
unless `required: "true"`.

Run it in every job that needs it, after `actions/checkout` and inside the job's
`container:` if it has one (files go to that container's `$HOME`). The image needs
`curl` or `wget`.

## Ant side (OKE instance)

- GitHub OIDC audience `https://ant.azrty.com`.
- Trust rules for org `azrtydxb`, any repo: `refs/heads/main`, `refs/heads/master` and
  `refs/tags/*` act as service principal `github-actions-azrtydxb-publish` (read on
  the language and mirror feeds, read and publish on `oci-hosted`). Every other ref
  acts as `github-actions-azrtydxb-ci` (read only).
