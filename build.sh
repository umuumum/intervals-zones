#!/usr/bin/env bash
# Build / sideload helper for the Zones 42d Connect IQ app.
#
#   ./build.sh --list                 show device ids your SDK has files for
#   ./build.sh                        build for DEVICE (default fenix9pro51mm)
#   DEVICE=fenix947mm ./build.sh      build for another watch
#   ./build.sh --install              build, then copy to a mounted watch
#
# Needs: Connect IQ SDK on PATH (monkeyc, connectiq) and a developer key.
set -euo pipefail

DEVICE="${DEVICE:-fenix9pro51mm}"
NAME="zones42d"
OUT="bin/${NAME}-${DEVICE}.prg"
KEY="${CIQ_KEY:-$HOME/.Garmin/developer_key.der}"

SDK_DEVICES="$HOME/Library/Application Support/Garmin/ConnectIQ/Devices"

if [[ "${1:-}" == "--list" ]]; then
    if [[ -d "$SDK_DEVICES" ]]; then
        ls -1 "$SDK_DEVICES"
    else
        echo "No device files at $SDK_DEVICES -- open the SDK Manager and download some." >&2
        exit 1
    fi
    exit 0
fi

if ! command -v monkeyc >/dev/null 2>&1; then
    echo "monkeyc not on PATH. Add <sdk>/bin to PATH (see README)." >&2
    exit 1
fi

if [[ ! -f "$KEY" ]]; then
    echo "No developer key at $KEY." >&2
    echo "Generate one:  openssl genrsa -out developer_key.pem 4096 &&" >&2
    echo "  openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem \\" >&2
    echo "    -out $KEY -nocrypt" >&2
    exit 1
fi

if [[ -d "$SDK_DEVICES" && ! -d "$SDK_DEVICES/$DEVICE" ]]; then
    echo "SDK has no device files for '$DEVICE'. Available:" >&2
    ls -1 "$SDK_DEVICES" >&2
    exit 1
fi

mkdir -p bin

# -l 0 turns the type checker off. The source is written to compile cleanly
# either way, but the checker's strictness moves between SDK point releases and
# a sideload is not worth fighting it over.
monkeyc \
    --jungles monkey.jungle \
    --device "$DEVICE" \
    --output "$OUT" \
    --private-key "$KEY" \
    --typecheck 0 \
    --warn \
    --release

echo "built $OUT"

if [[ "${1:-}" == "--install" ]]; then
    for mount in /Volumes/GARMIN /Volumes/fenix*; do
        if [[ -d "$mount/GARMIN/Apps" ]]; then
            cp "$OUT" "$mount/GARMIN/Apps/${NAME}.prg"
            echo "copied to $mount/GARMIN/Apps/${NAME}.prg -- eject, then restart the watch"
            exit 0
        fi
    done
    echo "No mounted Garmin found. Connect the watch over USB (MTP) and retry." >&2
    exit 1
fi
