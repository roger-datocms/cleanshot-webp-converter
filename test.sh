#!/bin/zsh
# Runs the test suite. Command Line Tools (without Xcode) ships swift-testing outside SwiftPM's search paths.
set -euo pipefail
cd ${0:A:h}

flags=()
if [[ $(xcode-select -p) == */CommandLineTools ]]; then
  dev=$(xcode-select -p)/Library/Developer
  flags=(-Xswiftc -F -Xswiftc $dev/Frameworks -Xlinker -rpath -Xlinker $dev/Frameworks -Xlinker -rpath -Xlinker $dev/usr/lib)
fi

swift test $flags "$@"
