#!/bin/bash
cat <<'EOF'
raw $HOME not expanded
EOF
cat <<EXPAND
expanded: $HOME
EOF
DIR="/tmp/a b"
echo "hash # not comment"
echo 'single $notvar'
case "$x" in
  a) echo A ;;
  b) echo B ;;
esac
