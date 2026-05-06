#!/bin/sh

# Build dependencies
# sudo apt install cmake build-essential extra-cmake-modules qt6-base-dev libkf6kio-dev kf6-kdbusaddons-dev libkf6i18n-dev kf6-kiconthemes-dev kf6-kxmlgui-dev libxapian-dev libapt-pkg-dev libpolkit-qt6-1-dev debhelper curl

# Runtime dependencies
# apt-xapian-index software-properties-qt

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUON_VERSION="6.0.0"
PKG_DIR="$SCRIPT_DIR/build/pkg"

# Install build dependencies
sudo apt install -y cmake build-essential extra-cmake-modules qt6-base-dev libkf6kio-dev kf6-kdbusaddons-dev libkf6i18n-dev kf6-kiconthemes-dev kf6-kxmlgui-dev libxapian-dev libapt-pkg-dev libpolkit-qt6-1-dev debhelper curl

# ============================================================
# 1. Build libqapt (Qt6/KF6) — install to a staging prefix
# ============================================================
echo "=== Building libqapt (Qt6/KF6) ==="
LIBQAPT_DIR="$SCRIPT_DIR/../libqapt"
if [ ! -d "$LIBQAPT_DIR" ]; then
    echo "Downloading libqapt sources..."
    curl -L "https://invent.kde.org/api/v4/projects/19666/repository/archive.tar.gz?sha=kf-6" -o /tmp/libqapt.tar.gz
    mkdir -p "$LIBQAPT_DIR"
    tar xzf /tmp/libqapt.tar.gz -C "$LIBQAPT_DIR" --strip-components=1
    rm /tmp/libqapt.tar.gz
fi

LIBQAPT_STAGE="$SCRIPT_DIR/build/libqapt-stage"
rm -rf "$LIBQAPT_DIR/build" "$LIBQAPT_STAGE"
mkdir -p "$LIBQAPT_DIR/build" "$LIBQAPT_STAGE"
cd "$LIBQAPT_DIR/build"
cmake -DCMAKE_BUILD_TYPE=Release -DQT_MAJOR_VERSION=6 \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DKDE_INSTALL_INCLUDEDIR=include \
    -DINCLUDE_INSTALL_DIR=include ..
make -j"$(nproc)"
DESTDIR="$LIBQAPT_STAGE" make install
# Copy generated export header
cp "$LIBQAPT_DIR/build/src/qapt_export.h" "$LIBQAPT_STAGE/usr/include/qapt/"

# Also install to system for muon compilation
sudo make install
sudo cp "$LIBQAPT_DIR/build/src/qapt_export.h" /usr/include/qapt/
sudo ldconfig
echo "=== libqapt built ==="

# ============================================================
# 2. Build muon
# ============================================================
echo "=== Building muon ==="
cd "$SCRIPT_DIR"
rm -rf build/muon-build
mkdir -p build/muon-build && cd build/muon-build
cmake -DCMAKE_BUILD_TYPE=Release -DQT_MAJOR_VERSION=6 "$SCRIPT_DIR"
make -j"$(nproc)"

MUON_STAGE="$SCRIPT_DIR/build/muon-stage"
rm -rf "$MUON_STAGE"
mkdir -p "$MUON_STAGE"
DESTDIR="$MUON_STAGE" make install
echo "=== muon built ==="

# ============================================================
# 3. Assemble .deb with embedded libqapt
# ============================================================
echo "=== Packaging .deb ==="
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN"

# Copy muon files
cp -a "$MUON_STAGE"/* "$PKG_DIR/"

# Embed libqapt .so files
cp -a "$LIBQAPT_STAGE/usr/lib" "$PKG_DIR/usr/" 2>/dev/null || true
# Remove dev files (headers, cmake, pkgconfig) — not needed at runtime
rm -rf "$PKG_DIR/usr/include" \
       "$PKG_DIR/usr/lib/x86_64-linux-gnu/cmake" \
       "$PKG_DIR/usr/lib/x86_64-linux-gnu/pkgconfig" \
       "$PKG_DIR/usr/lib/x86_64-linux-gnu/qt6" \
       "$PKG_DIR/usr/share/ECM"

# Compute installed size in KB
INSTALLED_SIZE=$(du -sk "$PKG_DIR" | cut -f1)

# Generate dependencies (excluding libqapt since it's bundled)
# Create minimal debian structure for dpkg-shlibdeps
mkdir -p "$PKG_DIR/debian"
echo "Source: muon" > "$PKG_DIR/debian/control"
DEPS=$(cd "$PKG_DIR" && dpkg-shlibdeps --ignore-missing-info -O usr/bin/muon usr/lib/x86_64-linux-gnu/libQApt.so.* 2>/dev/null | sed 's/shlibs:Depends=//')
DEPS=$(echo "$DEPS" | tr ',' '\n' | grep -vi "libqapt" | sed 's/^ *//;s/ *$//;/^$/d' | paste -sd, -)
rm -rf "$PKG_DIR/debian"

# Compose final Depends (avoid leading/trailing commas if DEPS is empty)
EXTRA_DEPS="apt-xapian-index, software-properties-qt"
if [ -n "$DEPS" ]; then
    FINAL_DEPS="$DEPS, $EXTRA_DEPS"
else
    FINAL_DEPS="$EXTRA_DEPS"
fi

cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: muon
Version: ${MUON_VERSION}-1
Architecture: $(dpkg --print-architecture)
Maintainer: Olivier Booklage <olivier@booklage.fr>
Installed-Size: ${INSTALLED_SIZE}
Depends: ${FINAL_DEPS}
Conflicts: libqapt3
Description: APT package manager for KDE
 Muon is a graphical package manager for Debian/Ubuntu
 based systems using KDE Frameworks 6.
 This package bundles libqapt (Qt6/KF6).
EOF

# Build .deb
DEB_FILE="$SCRIPT_DIR/muon_${MUON_VERSION}-1_$(dpkg --print-architecture).deb"
dpkg-deb --build "$PKG_DIR" "$DEB_FILE"

echo "=== .deb package built ==="
ls -lh "$DEB_FILE"
echo ""
echo "Install with: sudo apt install ./$DEB_FILE"
