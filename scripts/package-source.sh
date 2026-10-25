#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
core="$1"
version="${2:-}"
cd "$root"
if [ -z "$version" ]; then
  version="$(sed -n 's/^version: \([^+ ]*\)+[0-9][0-9]*$/\1/p' pubspec.yaml | head -1)"
fi
if [ -z "$version" ]; then echo 'Could not read version from pubspec.yaml' >&2; exit 1; fi
mkdir -p dist
git ls-files -z > .build/source-files.list
if [ ! -s .build/source-files.list ]; then echo 'Stage all sources in Git first' >&2; exit 1; fi
tar --null -T .build/source-files.list -czf "dist/Aster-Desktop-$version-source.tar.gz"
tar -C "$core" -czf dist/Aster-Core-a9a33503-source.tar.gz .
