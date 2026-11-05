#!/bin/zsh
# Builds libghostty-vt and full libghostty (GhosttyKit) from the pinned Ghostty commit and puts
# the two xcframeworks where the benchmark packages expect them. Needs Zig 0.17 (brew install zig)
# and Xcode. The frameworks are build output (~200 MB) and stay out of git.
set -euo pipefail
here=${0:A:h}/..
commit=${GHOSTTY_COMMIT:-c7f68a7f48c6a5b357689eb8c2328bc2dab5d8ed}
src=${GHOSTTY_SRC:-$here/.ghostty}
if [[ ! -d $src ]]; then git clone https://github.com/ghostty-org/ghostty $src; fi
git -C $src fetch -q origin $commit && git -C $src checkout -q $commit
(cd $src && zig build -Demit-lib-vt -Doptimize=ReleaseFast)
(cd $src && zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native)
rm -rf $here/VTBench/GhosttyVt.xcframework $here/TermBench/GhosttyVt.xcframework $here/TermBench/GhosttyKit.xcframework
cp -R $src/zig-out/lib/ghostty-vt.xcframework $here/VTBench/GhosttyVt.xcframework
cp -R $src/zig-out/lib/ghostty-vt.xcframework $here/TermBench/GhosttyVt.xcframework
cp -R $src/macos/GhosttyKit.xcframework $here/TermBench/GhosttyKit.xcframework
echo "Ghostty $commit built."
