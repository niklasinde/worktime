# Sourced by build.sh. Without Xcode the toolchain lacks the SwiftUIMacros plugin, so the macOS 27 SDK cannot compile @State.
# The macOS 26.5 SDK in the Command Line Tools can, but its stdlib lacks RawSpan.load, which SwiftTerm uses behind
# compiler(>=6.4); that branch is switched off in the checkout and SwiftTerm falls back to its scalar loop.
if ! ls "$(dirname "$(xcrun --find swiftc)")"/../lib/swift/host/plugins/libSwiftUIMacros* >/dev/null 2>&1 \
    && [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
    [ "${RELEASE:-0}" = 1 ] && { echo "error: a universal release build needs Xcode; the Command Line Tools have no x86_64 Swift libraries"; exit 1; }
    echo "warning: no Xcode, building against $SDKROOT"
    swift package resolve
    { grep -rl 'compiler(>=6\.4)' .build/checkouts/SwiftTerm/Sources || true; } | xargs -n1 sed -i '' 's/compiler(>=6\.4)/compiler(>=7.0)/'
fi
