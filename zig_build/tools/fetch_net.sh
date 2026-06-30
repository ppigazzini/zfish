#!/bin/sh
# zfish net fetcher. Downloads the NNUE net the Zig binary ACTUALLY loads -- read from the authoritative
# Zig constant `default_eval_file_name` in zig_build/support/engine.zig -- NOT the stale upstream
# src/evaluate.h that scripts/net.sh keys on. After an upstream net bump the Zig binary's net diverges
# from src/evaluate.h, so the upstream downloader fetches the wrong file and the binary crashes; this
# tracks the binary instead. Same download sources + sha256 validation as scripts/net.sh.
#
# Run with cwd = the net's runtime dir (src/).  $1 = path to zig_build/support/engine.zig
set -e

ENGINE="$1"
[ -f "$ENGINE" ] || { >&2 echo "fetch_net: engine.zig not found at '$ENGINE'"; exit 1; }
_filename=$(sed -n 's/.*default_eval_file_name = "\(nn-[0-9a-f]\{12\}\.nnue\)".*/\1/p' "$ENGINE" | head -1)
[ -n "$_filename" ] || { >&2 echo "fetch_net: no default_eval_file_name in $ENGINE"; exit 1; }

wget_or_curl=$( (command -v wget >/dev/null 2>&1 && echo "wget -qO- --timeout=300 --tries=1") ||
  (command -v curl >/dev/null 2>&1 && echo "curl -skL --max-time 300"))
sha256sum=$( (command -v shasum >/dev/null 2>&1 && echo "shasum -a 256") ||
  (command -v sha256sum >/dev/null 2>&1 && echo "sha256sum"))

validate() {  # $1 = file; remove + fail if the sha-named file doesn't match its contents
  if [ -n "$sha256sum" ] && [ -f "$1" ]; then
    if [ "$1" != "nn-$($sha256sum "$1" | cut -c 1-12).nnue" ]; then rm -f "$1"; return 1; fi
  fi
}

if [ -f "$_filename" ] && validate "$_filename"; then
  echo "Existing $_filename validated, skipping download"
  exit 0
fi
[ -n "$wget_or_curl" ] || { >&2 echo "fetch_net: neither wget nor curl installed."; exit 1; }

for url in \
  "https://tests.stockfishchess.org/api/nn/$_filename" \
  "https://github.com/official-stockfish/networks/raw/master/$_filename"; do
  echo "Downloading $_filename from $url ..."
  if $wget_or_curl "$url" >"$_filename" && validate "$_filename"; then
    echo "Successfully validated $_filename"
    exit 0
  fi
  rm -f "$_filename"
  echo "Failed from $url"
done
>&2 echo "fetch_net: failed to download $_filename"
exit 1
