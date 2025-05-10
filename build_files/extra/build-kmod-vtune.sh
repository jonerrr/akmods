#!/bin/sh

set -oeux pipefail

ARCH="$(rpm -E '%_arch')"
# KERNEL_NAME should be passed as an environment variable (e.g., from Dockerfile ARG)
# KERNEL_FLAVOR should also be passed if needed by the spec file (e.g., from Dockerfile ARG)
if [ -z "${KERNEL_NAME}" ]; then
    echo "Error: KERNEL_NAME environment variable is not set."
    exit 1
fi
KERNEL_VERSION="$(rpm -q "${KERNEL_NAME}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
if [ -z "${KERNEL_VERSION}" ]; then
    echo "Error: Could not determine KERNEL_VERSION from KERNEL_NAME=${KERNEL_NAME}."
    exit 1
fi
RELEASE="$(rpm -E '%fedora')"
INTEL_REPO_FILE="/etc/yum.repos.d/oneAPI.repo"
VTUNE_INSTALL_ROOT="/opt/intel/oneapi" # Standard root for oneAPI
VTUNE_DEFAULT_DIR="${VTUNE_INSTALL_ROOT}/vtune/latest"
SEPDK_SRC_DIR="${VTUNE_DEFAULT_DIR}/sepdk/src"

# Create the Intel oneAPI repository file
tee "${INTEL_REPO_FILE}" >/dev/null <<EOF
[oneAPI]
name=Intel® oneAPI repository
baseurl=https://yum.repos.intel.com/oneapi
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
EOF

export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH}"
echo "Current PATH before DNF: ${PATH}" # Add this line

# dnf install -y \
#     intel-oneapi-vtune \
#     rpm-build \
#     make \
#     gcc
dnf install -y \
    coreutils \
    grep \
    sed \
    gawk \
    findutils \
    which \
    util-linux \
    intel-oneapi-vtune \
    rpm-build \
    make \
    gcc

# Determine the actual VTune installation directory for sepdk/src
# if [ ! -d "${SEPDK_SRC_DIR}" ]; then
#     echo "Info: VTune sepdk source directory not found at default ${SEPDK_SRC_DIR}, attempting to find latest versioned directory."
#     # Find the latest versioned directory, e.g., /opt/intel/oneapi/vtune/202X.Y.Z
#     VTUNE_VERSIONED_DIR=$(find "${VTUNE_INSTALL_ROOT}/vtune/" -maxdepth 1 -type d -name '2*' | sort -V | tail -n 1)
#     if [ -n "${VTUNE_VERSIONED_DIR}" ] && [ -d "${VTUNE_VERSIONED_DIR}/sepdk/src" ]; then
#         SEPDK_SRC_DIR="${VTUNE_VERSIONED_DIR}/sepdk/src"
#         echo "Info: Found sepdk source directory at ${SEPDK_SRC_DIR}"
#     else
#         echo "Error: Could not find VTune sepdk source directory. Searched default and versioned paths."
#         echo "Listing contents of ${VTUNE_INSTALL_ROOT}/vtune/:"
#         ls -la "${VTUNE_INSTALL_ROOT}/vtune/" || echo " (failed to list)"
#         exit 1
#     fi
# fi
cd "${SEPDK_SRC_DIR}"

# Build the driver modules
# The --kernel-src-dir should point to the headers for the *target* kernel.
KERNEL_SRC_DIR="/usr/src/kernels/${KERNEL_VERSION}"
if [ ! -d "${KERNEL_SRC_DIR}" ]; then
    echo "Error: Kernel source directory not found at ${KERNEL_SRC_DIR}"
    echo "Please ensure kernel-devel-${KERNEL_NAME} (version ${KERNEL_VERSION}) is installed correctly."
    exit 1
fi
echo "Building VTune drivers from ${PWD} for kernel ${KERNEL_VERSION} using sources at ${KERNEL_SRC_DIR}"
./build-driver -ni --kernel-version="${KERNEL_VERSION}" --kernel-src-dir="${KERNEL_SRC_DIR}"

# Build the RPM package using the provided spec file
RPMBUILD_TOPDIR="${PWD}/rpmbuild_temp"
mkdir -p "${RPMBUILD_TOPDIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# sepdk.spec is expected to be in the current directory (SEPDK_SRC_DIR)
if [ ! -f "sepdk.spec" ]; then
    echo "Error: sepdk.spec not found in ${PWD}"
    exit 1
fi

echo "Debug: Contents of sepdk.spec:"
cat sepdk.spec
echo "--- End of sepdk.spec ---"

cp sepdk.spec "${RPMBUILD_TOPDIR}/SPECS/"

# The build-driver script should have placed the .ko files where sepdk.spec expects them.
# Typically, the spec file will copy them from the build location during its %install phase.
echo "Building VTune kmod RPM using sepdk.spec for kernel ${KERNEL_VERSION}"
rpmbuild -bb "${RPMBUILD_TOPDIR}/SPECS/sepdk.spec" \
    --define "_topdir ${RPMBUILD_TOPDIR}" \
    --define "kversion ${KERNEL_VERSION}" \
    --define "kflav ${KERNEL_FLAVOR:-main}" # KERNEL_FLAVOR should be an ARG/ENV

# Determine the kmod name (e.g., "sep" or "vtune") from the spec or RPM filename.
# This is a guess; the actual name depends on sepdk.spec.
# Common pattern is kmod-<name>-<kernel_version>.<arch>.rpm
# We'll try to find any kmod RPM for the current kernel.
KMOD_RPM_PATH=$(find "${RPMBUILD_TOPDIR}/RPMS/${ARCH}/" -name "kmod-*-${KERNEL_VERSION}.${ARCH}.rpm" -print -quit)

if [ -z "${KMOD_RPM_PATH}" ]; then
    echo "Error: VTune kmod RPM not found after build in ${RPMBUILD_TOPDIR}/RPMS/${ARCH}/ for kernel ${KERNEL_VERSION}"
    echo "Listing contents of ${RPMBUILD_TOPDIR}/RPMS/${ARCH}/:"
    ls -la "${RPMBUILD_TOPDIR}/RPMS/${ARCH}/" || echo " (failed to list)"
    # Consider printing rpmbuild logs if they are captured to a file.
    exit 1
fi

echo "VTune kmod RPM built successfully: ${KMOD_RPM_PATH}"

# Determine the kmod name from the RPM filename (e.g., "sep" from "kmod-sep-...")
KMOD_NAME_FROM_RPM=$(basename "${KMOD_RPM_PATH}" | sed -n "s/^kmod-\([a-zA-Z0-9_-]*\)-${KERNEL_VERSION}\.${ARCH}\.rpm$/\1/p")
if [ -z "${KMOD_NAME_FROM_RPM}" ]; then
    echo "Warning: Could not reliably determine kmod name from RPM filename: $(basename "${KMOD_RPM_PATH}")"
    echo "Defaulting to 'vtune' for destination directory. Verify this is correct for dual-sign.sh."
    KMOD_NAME_FOR_DIR="vtune"
else
    echo "Info: Determined kmod name as '${KMOD_NAME_FROM_RPM}' from RPM."
    KMOD_NAME_FOR_DIR="${KMOD_NAME_FROM_RPM}"
fi

# Copy the kmod RPM to the location expected by dual-sign.sh
DEST_KMOD_PARENT_DIR="/var/cache/akmods"
DEST_KMOD_DIR="${DEST_KMOD_PARENT_DIR}/${KMOD_NAME_FOR_DIR}"
mkdir -p "${DEST_KMOD_DIR}"
cp "${KMOD_RPM_PATH}" "${DEST_KMOD_DIR}/"
echo "Copied $(basename "${KMOD_RPM_PATH}") to ${DEST_KMOD_DIR}/"

# Verification
if [ ! -f "${DEST_KMOD_DIR}/$(basename "${KMOD_RPM_PATH}")" ]; then
    echo "Error: Failed to copy RPM to ${DEST_KMOD_DIR}"
    exit 1
fi
echo "VTune kmod RPM for ${KMOD_NAME_FOR_DIR} is ready for signing."

# Clean up
rm -rf "${RPMBUILD_TOPDIR}"
rm -f "${INTEL_REPO_FILE}"

echo "VTune kmod build script finished successfully."
