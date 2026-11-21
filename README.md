# php-cli-capsula

> **Experiment.** Tiny static base images for Deployer-style CI/deploy containers.
> Not a general-purpose PHP runtime. APIs and contents may change without notice.

Minimal `FROM scratch` images published to **GHCR only** (no Docker Hub):

```text
ghcr.io/rechtlogisch/php-cli-capsula:<php>
```

Multi-arch: `linux/amd64` + `linux/arm64`.

## What's inside

| Path | Contents |
| --- | --- |
| `/usr/local/bin/php` | Fully static musl PHP CLI |
| `/usr/bin/ssh`, `ssh-agent`, `ssh-add`, `ssh-keyscan` | Static OpenSSH portable client |
| `/bin/busybox` (+ applets) | Static BusyBox (ash as `sh`/`bash`) |
| `/etc/ssl/certs/ca-certificates.crt` | CA bundle for curl/mbedTLS |
| `/etc/passwd`, `/etc/group` | Minimal (`root`) |
| `/tmp` (mode `1777`), `/root/.ssh` | Runtime dirs |
| `/usr/bin/env` | BusyBox symlink |

### PHP: curl + iconv only

Configured with:

```text
--disable-all --enable-cli --disable-cgi --disable-phpdbg --without-pear
--without-pcre-jit --with-curl --with-iconv
```

- **8.3 / 8.4:** also `--disable-opcache`
- **8.5+:** OPcache cannot be disabled; `lexbor` + `uri` appear in `php -m`

**Why only curl + iconv?** Deployer v8 vendor install was tested without needing
`posix`, `phar`, or `zlib` in this image. Keeping the surface tiny is the point.

Static **libcurl** is built from source: HTTP/HTTPS only, TLS via **mbedTLS**
(Alpine `mbedtls-static`), CA path `/etc/ssl/certs/ca-certificates.crt`.
No brotli / zstd / nghttp2 / idn2 / psl / c-ares / LDAP / other protocols.
Iconv comes from **musl**.

### OpenSSH: ed25519 only

OpenSSH is built **`--without-openssl`** (also without zlib/PAM/libedit, no
security-key / PKCS11). Only the built-in crypto remains.

**Use ed25519 keys only.** RSA, ECDSA, and other OpenSSL-backed algorithms will
not work. Document this in any consumer image or Deployer recipe.

### BusyBox

Committed `busybox.config` is an `allnoconfig` base plus applets typically used
by CI/deploy scripts (`cat`, `cp`, `mv`, `rm`, `ls`, `mkdir`, `chmod`, `ln`,
`echo`, `printf`, `test`/`[`/`[[`, `tr`, `grep`, `sed`, `head`, `tail`, `cut`,
`env`, `id`, `whoami`, `find`, `xargs`, `timeout`, `sleep`, `date`, `wc`,
`sort`, `uniq`, `dirname`, `basename`, `readlink`, `realpath`, `touch`, `tar`,
`unzip`), with **ash** as both `sh` and `bash` (`SH_IS_ASH`, `BASH_IS_ASH`) and
`FEATURE_SH_MATH` so Deployer `runLocally` can invoke `bash`.

## Tags

| Tag | Meaning |
| --- | --- |
| `8.3`, `8.4`, `8.5`, `8.6` | Latest patch of that minor (no 8.2) |
| `8.6.0` (etc.) | Full version pin |
| `latest` | Same as `8.6` |

## Sizes (linux/amd64)

Prior research vs measured on this repo’s Dockerfiles (Nov 2026 local build):

| Component | Research | amd64 measured | arm64 measured |
| --- | --- | --- | --- |
| PHP 8.3 binary | ~5.0 MB | **4.80 MB** | **5.01 MB** |
| PHP 8.4 binary | ~5.1 MB | *(CI)* | *(CI)* |
| PHP 8.5 / 8.6 binary | ~7.9 MB | **8.6: 9.74 MB** | **8.6: 9.58 MB** |
| Capsula rootfs 8.3 | — | **6.83 MB** | **7.25 MB** |
| Capsula rootfs 8.6 | — | **11.78 MB** | **11.83 MB** |
| OpenSSH client (`ssh`) | — | **0.65 MB** | **0.69 MB** |
| BusyBox | — | **0.26 MB** | **0.31 MB** |
| Whole deployer image using this base | ~8.8–11.8 MB | *(consumer)* | *(consumer)* |

PHP 8.6 is larger than the earlier ~7.9 MB estimate (OPcache + lexbor + uri are
unavoidable on 8.5+; curl/mbedTLS static link also adds weight). CI prints
measured byte sizes into the job summary on every build.

## How to use

Copy the entire rootfs into your own scratch/distroless image:

```dockerfile
FROM scratch
COPY --from=ghcr.io/rechtlogisch/php-cli-capsula:8.6 / /
# … your Deployer / app bits …
```

Or start from a specific minor/full version tag.

Private GHCR pull example:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u USER --password-stdin
docker pull ghcr.io/rechtlogisch/php-cli-capsula:8.6
```

## CI / publishing

Workflow: `.github/workflows/build-and-publish.yml`

| Event | Build + smoke | Push to GHCR |
| --- | --- | --- |
| `pull_request` | yes | **no** |
| `push` to `main` | yes | yes |
| `schedule` (weekly) | yes | yes |
| `workflow_dispatch` | yes | yes |

Native builds (no QEMU): amd64 on `ubuntu-24.04`, arm64 on `ubuntu-24.04-arm`.
Per-arch images are pushed **by digest**, then merged into multi-arch manifests
with `docker buildx imagetools`. Provenance `mode=max`, SBOM enabled on publish.

After a successful publish on `main`, a `repository_dispatch` of type
`capsula-updated` is sent to `rechtlogisch/deployer` using secret
`DEPLOYER_DISPATCH_TOKEN` (skipped with a notice if the secret is missing).

## Local build

```bash
docker build --build-arg PHP_VERSION=8.6.0 -t php-cli-capsula:8.6 .
./scripts/smoke-test.sh php-cli-capsula:8.6 8.6
```

Apple Silicon / `linux/arm64` works the same way (Docker Desktop). The PHP
stage needs Alpine `linux-headers` so `ext/standard/crc32.c` can include
`<asm/hwcap.h>` (`HWCAP_CRC32`); that package is already in the Dockerfile.
Cross-building with QEMU is slow; prefer a native arm64 builder when possible.
CI already builds arm64 natively on `ubuntu-24.04-arm` for every PR.

## License

MIT — Copyright RL Recht logisch GmbH & Co. KG. See [LICENSE](LICENSE).

Upstream components (PHP, curl, mbedTLS, OpenSSH, BusyBox, Alpine CA bundle)
retain their own licenses.
