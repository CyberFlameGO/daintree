cd "$(dirname "$0")"
objdump -dSl --prefix=. --prefix-strip=4 os/zig-cache/bin/dainkrnl|less
