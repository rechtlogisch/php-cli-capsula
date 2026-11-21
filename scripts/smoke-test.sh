#!/bin/sh
# Smoke-test a php-cli-capsula image (local tag or registry ref).
# Usage: smoke-test.sh <image> <php-major-minor>
# Example: ./scripts/smoke-test.sh capsula:8.6 8.6
#
# Set DOCKER="sudo docker" if the current user cannot talk to the daemon.
set -eu

IMAGE="${1:?image ref required}"
PHP_MM="${2:?php major.minor required (e.g. 8.6)}"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
EXPECTED="${ROOT}/expected/php-modules-${PHP_MM}.txt"
DOCKER="${DOCKER:-docker}"

if [ ! -f "${EXPECTED}" ]; then
  echo "missing expected modules file: ${EXPECTED}" >&2
  exit 1
fi

run() {
  ${DOCKER} run --rm --network=host "${IMAGE}" "$@"
}

echo "==> php -v"
run php -v

echo "==> php -m (exact match vs expected/${PHP_MM})"
ACTUAL="$(mktemp)"
EXPECTED_NORM="$(mktemp)"
# Normalize: strip trailing whitespace on each line, then trailing blank lines
run php -m | sed 's/[[:space:]]*$//' | sed -e :a -e '/^$/{$d;N;ba' -e '}' > "${ACTUAL}"
sed 's/[[:space:]]*$//' "${EXPECTED}" | sed -e :a -e '/^$/{$d;N;ba' -e '}' > "${EXPECTED_NORM}"
if ! diff -u "${EXPECTED_NORM}" "${ACTUAL}"; then
  echo "php -m mismatch for ${PHP_MM}" >&2
  cat "${ACTUAL}" >&2
  exit 1
fi
rm -f "${ACTUAL}" "${EXPECTED_NORM}"

echo "==> HTTPS via curl extension (Packagist)"
run php -r '$c=curl_init("https://repo.packagist.org/packages.json");curl_setopt($c,CURLOPT_RETURNTRANSFER,1);curl_setopt($c,CURLOPT_FOLLOWLOCATION,1);$b=curl_exec($c);if($b===false){fwrite(STDERR,curl_error($c)."\n");exit(1);} exit(0);'

echo "==> iconv (musl; no //TRANSLIT)"
run php -r 'if(!function_exists("iconv")){fwrite(STDERR,"iconv missing\n");exit(1);} $o=iconv("UTF-8","UTF-8","caf\xc3\xa9"); if($o===false||strlen($o)!==5){fwrite(STDERR,"iconv failed\n");exit(1);} echo "iconv ok\n";'

echo "==> ssh -V"
run ssh -V

echo "==> bash (BusyBox ash as bash)"
run bash -c 'echo ok'

echo "==> ssh-agent / ssh-add ed25519 flow"
# Image intentionally omits ssh-keygen; generate a throwaway key on the host.
KEYDIR="$(mktemp -d)"
trap 'rm -rf "${KEYDIR}"' EXIT
ssh-keygen -t ed25519 -N "" -f "${KEYDIR}/id_ed25519" -q
${DOCKER} run --rm \
  -v "${KEYDIR}/id_ed25519:/tmp/id_ed25519:ro" \
  -v "${KEYDIR}/id_ed25519.pub:/tmp/id_ed25519.pub:ro" \
  "${IMAGE}" \
  sh -c '
    set -eu
    eval "$(ssh-agent -s)"
    ssh-add /tmp/id_ed25519
    ssh-add -l
    # keyscan may fail offline; still exercise the binary
    ssh-keyscan -T 5 github.com >/dev/null 2>&1 || true
  '

echo "==> versions for summary"
run sh -c '
  echo "php: $(php -v | head -n 1)"
  echo "curl: $(php -r "echo curl_version()[\"version\"];")"
  ssh -V 2>&1 | head -n 1 | sed "s/^/openssh: /"
  echo "busybox: static $(wc -c < /bin/busybox) bytes"
  if [ -f /.capsula/sizes.env ]; then
    echo "--- sizes ---"
    cat /.capsula/sizes.env
  fi
'

echo "OK: smoke test passed for ${IMAGE} (PHP ${PHP_MM})"
