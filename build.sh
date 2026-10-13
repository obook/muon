#!/usr/bin/env bash
#
# Name: build.sh
# Description: Build the Muon Debian packages, one per distribution. Each one
#              is built in a container of the distribution it is for and ends
#              up in the build directory.
# Usage: ./build.sh                build every target
#        ./build.sh neon           build one target (neon or ubuntu26.04)
#        BUILD_DIR=/some/dir ./build.sh    to build somewhere else than build/
# Author: Olivier Booklage
# Date: October 2026
# License: same as Muon, see COPYING
#
# Why one package per distribution: KDE neon and Ubuntu name their Qt and KDE
# Frameworks packages differently, so the dependencies of one package do not
# resolve on the other. Ubuntu 24.04 is not a target: it has no KDE Frameworks 6.
#
# Why QApt is inside the package: Muon needs QApt 4, which no distribution
# ships. Its library and worker are versioned (libQApt.so.4, qaptworker4), so
# they install next to the QApt 3 of the distribution without touching it.
#
set -euo pipefail

readonly TARGETS="neon ubuntu26.04"

# QApt 4 sources, pinned to the commit the packages are tested with.
readonly QAPT_REPOSITORY="https://github.com/evgeniy-harchenko/qapt"
readonly QAPT_COMMIT="c708115b81392e3712d38ac68d3e46a3fea8c090"

# Debian revision: raise it when the package changes but Muon's version does not.
readonly PACKAGE_REVISION="3"
readonly MAINTAINER="Olivier Booklage <olivier@booklage.fr>"

# Packages that shared libraries cannot reveal: Muon calls them as programs.
readonly RUNTIME_PACKAGES="apt-xapian-index, software-properties-qt"

# Build packages. The KDE Frameworks ones have a name per distribution.
readonly COMMON_PACKAGES="g++ make cmake extra-cmake-modules gettext dpkg-dev pkg-config \
qt6-base-dev qt6-5compat-dev libxapian-dev libapt-pkg-dev libpolkit-qt6-1-dev"
readonly NEON_PACKAGES="kf6-kio-dev kf6-kdbusaddons-dev kf6-ki18n-dev \
kf6-kiconthemes-dev kf6-kxmlgui-dev"
readonly UBUNTU_PACKAGES="libkf6kio-dev libkf6dbusaddons-dev libkf6i18n-dev \
libkf6iconthemes-dev libkf6xmlgui-dev"

# The folder of this script, whatever folder it is called from.
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${BUILD_DIR:-${source_dir}/build}"
qapt_dir="${build_dir}/qapt-${QAPT_COMMIT}"

# Stop with a message that says what went wrong.
fail() {
    echo "build.sh: $1" >&2
    exit 1
}

# ---------------------------------------------------------------
#  ON THE HOST: prepare the sources and the containers
# ---------------------------------------------------------------

check_tools() {
    local tool
    for tool in docker curl tar; do
        if ! command -v "${tool}" > /dev/null; then
            fail "the program '${tool}' is missing."
        fi
    done
}

# Download the QApt sources once; later runs reuse them.
fetch_qapt() {
    if [ -f "${qapt_dir}/CMakeLists.txt" ]; then
        return
    fi
    mkdir -p "${build_dir}"
    echo "=== Downloading QApt ${QAPT_COMMIT} ==="
    if ! curl -fsSL "${QAPT_REPOSITORY}/archive/${QAPT_COMMIT}.tar.gz" | tar -xz -C "${build_dir}"; then
        fail "could not download the QApt sources."
    fi
}

# KDE neon has no base image: it is Ubuntu 24.04 plus the neon archive. The key
# is fetched from the archive it signs, so the fingerprint written here is what
# makes it trustworthy. It is the one of /etc/apt/keyrings/neon-archive-keyring.asc
# on a neon system.
print_neon_archive_setup() {
    cat << 'EOF'
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && curl -fsSL https://archive.neon.kde.org/public.key -o /tmp/neon.asc \
 && test "$(gpg --show-keys --with-colons /tmp/neon.asc | awk -F: '$1 == "fpr" { print $10; exit }')" \
    = "444DABCF3667D0283F894EDDE6D4736255751E5D" \
 && install -D -m 644 /tmp/neon.asc /etc/apt/keyrings/neon-archive-keyring.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/neon-archive-keyring.asc] https://archive.neon.kde.org/user noble main" \
    > /etc/apt/sources.list.d/neon.list
EOF
}

# Write the recipe of the build image of a target.
print_dockerfile() {
    local target="$1"
    local packages
    case "${target}" in
        neon)
            echo "FROM ubuntu:24.04"
            print_neon_archive_setup
            packages="${COMMON_PACKAGES} ${NEON_PACKAGES}"
            ;;
        ubuntu26.04)
            echo "FROM ubuntu:26.04"
            packages="${COMMON_PACKAGES} ${UBUNTU_PACKAGES}"
            ;;
        *)
            fail "unknown target '${target}'. Targets: ${TARGETS}"
            ;;
    esac
    echo "RUN apt-get update \\"
    echo " && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${packages}"
}

# Docker keeps the image, so only the first run installs the build packages.
# "docker image rm muon-build:<target>" makes the next run install them again.
build_in_container() {
    local target="$1"
    local image="muon-build:${target}"
    local dockerfile
    dockerfile="$(print_dockerfile "${target}")"

    echo "=== ${target}: preparing the build image ==="
    echo "${dockerfile}" | docker build --tag "${image}" -

    # The container works as the calling user, so that the build directory
    # does not fill up with files owned by root.
    echo "=== ${target}: building ==="
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        --env HOME=/tmp \
        --volume "${source_dir}:/src:ro" \
        --volume "${qapt_dir}:/qapt:ro" \
        --volume "${build_dir}:/out" \
        "${image}" /src/build.sh --in-container "${target}"
}

# ---------------------------------------------------------------
#  IN THE CONTAINER: compile and make the package
# ---------------------------------------------------------------

# Compile a CMake project and install it into the staging folder, which
# becomes the content of the package.
compile_and_stage() {
    local project_dir="$1"
    local project_build_dir="$2"
    local stage_dir="$3"
    shift 3

    cmake -S "${project_dir}" -B "${project_build_dir}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        "$@"
    cmake --build "${project_build_dir}" --parallel "$(nproc)"
    DESTDIR="${stage_dir}" cmake --install "${project_build_dir}" --strip
}

# QApt also installs what is needed to compile against it and the translations
# of tools that are not built. None of it belongs in the Muon package.
remove_unpackaged_files() {
    local stage_dir="$1"
    rm -rf "${stage_dir}/usr/include"
    rm -rf "${stage_dir}"/usr/lib/*/cmake "${stage_dir}"/usr/lib/*/pkgconfig "${stage_dir}"/usr/lib/*/qt6
    rm -f "${stage_dir}"/usr/lib/*/libQApt.so
    find "${stage_dir}/usr/share/locale" -type f ! -name "muon.mo" -delete
    find "${stage_dir}/usr/share/locale" -type d -empty -delete
}

# Ask dpkg which packages provide the shared libraries the programs load.
find_library_packages() {
    local work_dir="$1"
    local stage_dir="$2"

    # dpkg-shlibdeps only runs next to a debian/control file, even an empty one.
    mkdir -p "${work_dir}/debian"
    touch "${work_dir}/debian/control"
    # libQApt.so.4 is in the package itself: no other package provides it,
    # hence --ignore-missing-info.
    (cd "${work_dir}" && dpkg-shlibdeps -O --ignore-missing-info -S"${stage_dir}" \
        "${stage_dir}/usr/bin/muon" \
        "${stage_dir}/usr/bin/qaptworker4" \
        "${stage_dir}"/usr/lib/*/libQApt.so.4.*) | sed "s/^shlibs:Depends=//"
}

write_control_files() {
    local stage_dir="$1"
    local version="$2"
    local library_packages="$3"

    mkdir -p "${stage_dir}/DEBIAN"
    cat > "${stage_dir}/DEBIAN/control" << EOF
Package: muon
Version: ${version}
Architecture: $(dpkg --print-architecture)
Maintainer: ${MAINTAINER}
Section: admin
Priority: optional
Homepage: https://github.com/obook/muon
Depends: ${library_packages}, ${RUNTIME_PACKAGES}
Description: APT package manager for KDE
 Muon is a graphical package manager for KDE: search, install and remove
 packages, inspect their versions and their dependencies.
 .
 This package also contains the QApt 4 library and its worker, which Muon
 needs and which the distribution does not provide.
EOF
    # The package installs a shared library: the system has to refresh the
    # list of libraries it knows, or Muon would not find libQApt.so.4.
    echo "activate-noawait ldconfig" > "${stage_dir}/DEBIAN/triggers"
}

build_package() {
    local target="$1"
    local work_dir="/out/${target}"
    local stage_dir="${work_dir}/stage"
    local muon_version
    muon_version="$(sed -n 's/^set(PROJECT_VERSION "\(.*\)")/\1/p' /src/CMakeLists.txt)"
    local version="${muon_version}-${PACKAGE_REVISION}"

    rm -rf "${stage_dir}"
    compile_and_stage /qapt "${work_dir}/qapt" "${stage_dir}"
    # Muon includes <QApt/...>, so the compiler has to be told where the
    # staged headers are: they are not in /usr/include.
    compile_and_stage /src "${work_dir}/muon" "${stage_dir}" \
        -DCMAKE_PREFIX_PATH="${stage_dir}/usr" \
        -DCMAKE_CXX_FLAGS="-isystem ${stage_dir}/usr/include"
    remove_unpackaged_files "${stage_dir}"

    local library_packages
    library_packages="$(find_library_packages "${work_dir}" "${stage_dir}")"
    write_control_files "${stage_dir}" "${version}" "${library_packages}"

    # Packages of earlier runs would make it unclear which one is new.
    rm -f /out/muon_*_"${target}"_*.deb
    local package="/out/muon_${version}_${target}_$(dpkg --print-architecture).deb"
    dpkg-deb --root-owner-group --build "${stage_dir}" "${package}"
}

# ---------------------------------------------------------------
#  ENTRY POINT
# ---------------------------------------------------------------

if [ "${1:-}" = "--in-container" ]; then
    build_package "$2"
    exit 0
fi

check_tools
fetch_qapt
for target in ${*:-${TARGETS}}; do
    build_in_container "${target}"
done

echo
echo "Packages:"
ls -1 "${build_dir}"/muon_*.deb
echo "Install the one of your system with: sudo apt install ./build/muon_<version>_<target>_amd64.deb"
