#!/bin/bash
set -euo pipefail

NAME="${1:-world}"
echo "Hello, ${NAME}!"

for f in *.txt; do
    echo "== $f =="
    cat "$f"
done
