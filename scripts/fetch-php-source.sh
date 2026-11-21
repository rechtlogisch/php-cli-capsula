#!/bin/sh
# Download PHP source from php.net and verify sha256 against releases JSON.
# Usage: fetch-php-source.sh <PHP_VERSION> [dest-dir]
set -eu
PHP_VERSION="${1:?PHP version required}"
DEST="${2:-.}"
META_URL="https://www.php.net/releases/index.php?json&version=${PHP_VERSION}&max=1"

wget -qO /tmp/php-release.json "${META_URL}"
SHA="$(PHP_VERSION="${PHP_VERSION}" python3 - <<'PY'
import json, os
info = json.load(open("/tmp/php-release.json"))
key = os.environ["PHP_VERSION"]
data = info.get(key) or info[next(iter(info))]
for s in data["source"]:
    if s["filename"].endswith(".tar.xz"):
        print(s["sha256"])
        break
else:
    raise SystemExit("tar.xz sha256 not found in php.net JSON")
PY
)"

echo "PHP ${PHP_VERSION} sha256=${SHA}"
cd "${DEST}"
wget -q "https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz"
echo "${SHA}  php-${PHP_VERSION}.tar.xz" | sha256sum -c -
tar xf "php-${PHP_VERSION}.tar.xz"
mv "php-${PHP_VERSION}" php
