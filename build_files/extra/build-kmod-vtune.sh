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
echo "Current PATH before DNF: ${PATH}"

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

echo "sepdk src dir ls: $(ls /opt/intel/oneapi/vtune/latest/sepdk/src/)"
# ls /opt/intel/oneapi/vtune/latest/sepdk/src/
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

# Modify sepdk.spec to work with pre-built .ko files instead of a source tarball
# 1. Comment out Source0 line
# 2. Comment out %setup -q line in %prep
# 3. Ensure %prep section still exists even if empty, or rpmbuild might complain.
#    Alternatively, remove %prep entirely if it becomes empty.
#    Let's try making %prep effectively a no-op.
echo "Modifying sepdk.spec to handle pre-built .ko files..."
cp sepdk.spec sepdk.spec.orig # Backup original
sed -i 's|^Source0:.*|# Source0: (Commented out by build-kmod-vtune.sh)|' sepdk.spec
# If %prep only contains %setup, we can comment out %setup and leave %prep.
# If %prep has other commands, only comment %setup.
# Assuming %prep only has %setup based on typical usage:
sed -i '/%prep/a # %setup -q (Commented out by build-kmod-vtune.sh)' sepdk.spec        # Add comment after %prep
sed -i 's|^%setup -q.*|# %setup -q (Commented out by build-kmod-vtune.sh)|' sepdk.spec # Comment the line itself

echo "Debug: Contents of modified sepdk.spec:"
cat sepdk.spec
echo "--- End of modified sepdk.spec ---"

cp sepdk.spec "${RPMBUILD_TOPDIR}/SPECS/"

# The build-driver script should have placed the .ko files where sepdk.spec expects them.
# Typically, the spec file will copy them from the build location during its %install phase.
echo "Building VTune kmod RPM using sepdk.spec for kernel ${KERNEL_VERSION}"

VTUNE_PRODUCT_VERSION=$(rpm -q --qf '%{VERSION}' intel-oneapi-vtune 2>/dev/null || echo "0.0.0")
KMOD_BASE_NAME="sep5" # Based on DRIVER_NAME=sep5 in insmod-sep
KMOD_VERSION="${VTUNE_PRODUCT_VERSION}"
KMOD_BUILD_RELEASE="1.fc${RELEASE}.${KERNEL_FLAVOR:-main}"

# Determine ARITY (smp or up)
ARITY="smp" # Default to smp for modern systems
if ! uname -v | grep -q SMP; then
    ARITY="up"
fi
echo "Info: Determined ARITY as '${ARITY}'"

rpmbuild -bb "${RPMBUILD_TOPDIR}/SPECS/sepdk.spec" \
    --define "_topdir ${RPMBUILD_TOPDIR}" \
    --define "kversion ${KERNEL_VERSION}" \
    --define "kflav ${KERNEL_FLAVOR:-main}" \
    --define "NAME ${KMOD_BASE_NAME}" \
    --define "VERS ${KMOD_VERSION}" \
    --define "BUILD_RELEASE ${KMOD_BUILD_RELEASE}" \
    --define "SEP_DRIVER_NAME ${KMOD_BASE_NAME}" \
    --define "ARCH ${ARCH}" \
    --define "ARITY ${ARITY}" \
    --define "IS_VTUNE_BUILD 1" \
    --define "DRIVER_GROUP vtune"

# Determine the kmod RPM path.
# The spec file defines: %define _rpmfilename %{NAME}-%{VERS}-%{release}.%{ARCH}.rpm
# So, the RPM name will be like sep5-2025.3.0-1.fc42.main.x86_64.rpm
EXPECTED_RPM_NAME="${KMOD_BASE_NAME}-${KMOD_VERSION}-${KMOD_BUILD_RELEASE}.${ARCH}.rpm"
KMOD_RPM_PATH=$(find "${RPMBUILD_TOPDIR}/RPMS/${ARCH}/" -name "${EXPECTED_RPM_NAME}" -print -quit)

if [ -z "${KMOD_RPM_PATH}" ]; then
    echo "Error: VTune kmod RPM '${EXPECTED_RPM_NAME}' not found after build in ${RPMBUILD_TOPDIR}/RPMS/${ARCH}/"
    echo "Listing contents of ${RPMBUILD_TOPDIR}/RPMS/${ARCH}/:"
    ls -la "${RPMBUILD_TOPDIR}/RPMS/${ARCH}/" || echo " (failed to list)"
    exit 1
fi

echo "VTune kmod RPM built successfully: ${KMOD_RPM_PATH}"

# The KMOD_NAME_FOR_DIR will be the base name of the RPM (e.g., "sep5")
# This is used for the destination directory for dual-sign.sh
KMOD_NAME_FOR_DIR="${KMOD_BASE_NAME}"
echo "Info: Using kmod name as '${KMOD_NAME_FOR_DIR}' for destination directory."

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
