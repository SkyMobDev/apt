#!/usr/bin/env bash
# Proves the two halves of a promotion agree and puts the .deb files where
# apt-ftparchive expects them: SHA256SUMS records exactly what the manifests
# name, and every file downloaded from the pool release matches its recorded
# hash. Run by the publish job before it signs anything, and by the pull request
# job on its own — which is why it holds no secrets and deploys nothing.
#
# Needs SUITES, ARCHS and POOL_RELEASE from the workflow, plus a GH_TOKEN that
# can read this repository's releases.
set -euo pipefail

expected=$(mktemp); recorded=$(mktemp)

# Checked against the union of the manifests, because the pool is shared: a file
# only beta names is legitimately there, and per-suite checking would call it
# stale.
for suite in $SUITES; do
  # Explicitly, because the process substitution below reports a missing file
  # only on stderr: the loop would read EOF and the suite would publish empty
  # with this step still green.
  [ -f "$suite.list" ] || { echo "::error::$suite.list is missing"; exit 1; }
  while read -r pkg version rest; do
    case "$pkg" in '') continue ;; esac
    { [ -n "$version" ] && [ -z "${rest:-}" ]; } ||
      { echo "::error::malformed $suite.list entry: $pkg $version $rest"; exit 1; }
    for arch in $ARCHS; do
      echo "${pkg}_${version}_${arch}.deb" >> "$expected"
    done
  done < <(sed 's/#.*//; s/\r$//' "$suite.list")
done

# stable carries the fleet; an empty one stops `apt install` resolving at all.
# beta is allowed to be empty, and between candidates it is.
grep -q '[^[:space:]]' < <(sed 's/#.*//' stable.list) ||
  { echo "::error::stable.list names no packages"; exit 1; }
sort -u -o "$expected" "$expected"

[ -f SHA256SUMS ] || { echo "::error::SHA256SUMS is missing"; exit 1; }
# Two spaces between hash and name, as sha256sum writes it and as the
# `sha256sum --strict -c` below requires.
if grep -v -E '^([0-9a-f]{64}  [^ /]+\.deb)?$' SHA256SUMS; then
  echo "::error::malformed SHA256SUMS lines above"
  exit 1
fi
awk 'NF { print $2 }' SHA256SUMS | sort > "$recorded"
if ! diff -u --label "named by the manifests" --label "recorded in SHA256SUMS" \
       "$expected" "$recorded"; then
  echo "::error::SHA256SUMS does not record exactly what stable.list + beta.list name"
  exit 1
fi

# Only the files SHA256SUMS records, each held to its recorded hash: an asset
# replaced on the release without a reviewed change to SHA256SUMS fails here.
mkdir -p downloads
patterns=()
while read -r name; do patterns+=(--pattern "$name"); done < <(awk 'NF { print $2 }' SHA256SUMS)
gh release download "$POOL_RELEASE" --repo "$GITHUB_REPOSITORY" --dir downloads "${patterns[@]}"
# Compared by name as well, so a missing asset is reported as the file it is
# rather than as whatever gh makes of an unmatched pattern.
if ! diff -u --label "recorded in SHA256SUMS" --label "downloaded from $POOL_RELEASE" \
       <(awk 'NF { print $2 }' SHA256SUMS | sort) <(ls -1 downloads | sort); then
  echo "::error::the $POOL_RELEASE release is missing files SHA256SUMS records"
  exit 1
fi
(cd downloads && sha256sum --strict -c ../SHA256SUMS)

# The filename is not the version. apt serves what the control file says, so a
# .deb renamed to a version it does not carry would publish under one number and
# install as another.
for deb in downloads/*.deb; do
  name="${deb##*/}"
  got="$(dpkg-deb -f "$deb" Package)_$(dpkg-deb -f "$deb" Version)_$(dpkg-deb -f "$deb" Architecture).deb"
  [ "$got" = "$name" ] || { echo "::error::$name carries $got"; exit 1; }
  pkg="${name%%_*}"
  dest="pool/main/$(printf %.1s "$pkg")/$pkg"
  mkdir -p "$dest"
  mv "$deb" "$dest/"
done
find pool -name '*.deb' | sort
