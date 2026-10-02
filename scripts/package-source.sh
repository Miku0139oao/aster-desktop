#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
core="$1"
cd "$root"
git ls-files -z > .build/source-files.list
if [ ! -s .build/source-files.list ]; then echo 'Stage all sources in Git first' >&2; exit 1; fi
tar --null -T .build/source-files.list -czf dist/Aster-Desktop-0.1.1-source.tar.gz
tar -C "$core" -czf dist/Aster-Core-a9a33503-source.tar.gz .
