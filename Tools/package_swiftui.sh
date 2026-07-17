#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="EC25 Toolbox"
EXECUTABLE_NAME="EC25Toolbox"
OUTPUT_APP="${EC25_OUTPUT_APP:-${ROOT_DIR}/dist/${APP_NAME}.app}"
CONFIGURATION="${EC25_BUILD_CONFIGURATION:-release}"

DEVELOPER_ROOT="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
SWIFT="${DEVELOPER_ROOT}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
SDK="${DEVELOPER_ROOT}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk"
PLUGIN_PATH="${DEVELOPER_ROOT}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

INFO_PLIST="${ROOT_DIR}/Resources/EC25Toolbox-Info.plist"
ICON_SOURCE="${ROOT_DIR}/Resources/EC25Toolbox.icon"

if [[ ! -x "${SWIFT}" ]]; then
    print -u2 "Swift toolchain not found: ${SWIFT}"
    exit 1
fi

if [[ ! -d "${SDK}" ]]; then
    print -u2 "macOS SDK not found: ${SDK}"
    exit 1
fi

/usr/bin/plutil -lint "${INFO_PLIST}" >/dev/null

BUILD_OPTIONS=(
    --disable-sandbox
    -c "${CONFIGURATION}"
    --sdk "${SDK}"
    -Xswiftc -plugin-path
    -Xswiftc "${PLUGIN_PATH}"
)

if [[ "${EC25_SKIP_SWIFT_BUILD:-0}" != "1" ]]; then
    DEVELOPER_DIR="${DEVELOPER_ROOT}" "${SWIFT}" build \
        "${BUILD_OPTIONS[@]}" \
        --product EC25Toolbox
fi

BIN_DIR="$(DEVELOPER_DIR="${DEVELOPER_ROOT}" "${SWIFT}" build "${BUILD_OPTIONS[@]}" --show-bin-path)"
EXECUTABLE="${BIN_DIR}/EC25Toolbox"
RESOURCE_BUNDLE="${BIN_DIR}/EC25Toolbox_EC25Toolbox.bundle"

if [[ ! -x "${EXECUTABLE}" ]]; then
    print -u2 "Built executable not found: ${EXECUTABLE}"
    exit 1
fi

if [[ ! -d "${RESOURCE_BUNDLE}" ]]; then
    print -u2 "Localization resource bundle not found: ${RESOURCE_BUNDLE}"
    exit 1
fi

STAGING_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ec25-toolbox-package.XXXXXX")"
STAGING_APP="${STAGING_ROOT}/${APP_NAME}.app"
trap '/bin/rm -rf "${STAGING_ROOT}"' EXIT

/bin/mkdir -p "${STAGING_APP}/Contents/MacOS" "${STAGING_APP}/Contents/Resources"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${EXECUTABLE}" "${STAGING_APP}/Contents/MacOS/${EXECUTABLE_NAME}"
if [[ "${EC25_REUSE_PACKAGED_LPAC:-0}" == "1" ]]; then
    EXISTING_LPAC="${OUTPUT_APP}/Contents/MacOS/lpac"
    if [[ ! -x "${EXISTING_LPAC}" ]]; then
        print -u2 "Existing packaged lpac not found: ${EXISTING_LPAC}"
        exit 1
    fi
    COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${EXISTING_LPAC}" "${STAGING_APP}/Contents/MacOS/lpac"
else
    /bin/zsh "${ROOT_DIR}/Tools/build_lpac.sh" "${STAGING_APP}/Contents/MacOS/lpac"
fi
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${RESOURCE_BUNDLE}" "${STAGING_APP}/Contents/Resources/EC25Toolbox_EC25Toolbox.bundle"
/bin/mkdir -p "${STAGING_APP}/Contents/Resources/ThirdParty/lpac"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ROOT_DIR}/ThirdParty/lpac/LICENSES" "${STAGING_APP}/Contents/Resources/ThirdParty/lpac/LICENSES"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ROOT_DIR}/ThirdParty/lpac/REUSE.toml" "${STAGING_APP}/Contents/Resources/ThirdParty/lpac/REUSE.toml"
/bin/mkdir -p "${STAGING_APP}/Contents/Resources/ThirdParty/EasyLPAC"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ROOT_DIR}/ThirdParty/EasyLPAC-LICENSE" "${STAGING_APP}/Contents/Resources/ThirdParty/EasyLPAC/LICENSE"
/bin/mkdir -p "${STAGING_APP}/Contents/Resources/ThirdParty/VoWiFi"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${ROOT_DIR}/ThirdParty/VoWiFi-NOTICE.md" "${STAGING_APP}/Contents/Resources/ThirdParty/VoWiFi/NOTICE.md"
DEVELOPER_DIR="${DEVELOPER_ROOT}" /usr/bin/xcrun actool \
    "${ICON_SOURCE}" \
    --compile "${STAGING_APP}/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 26.0 \
    --app-icon EC25Toolbox \
    --output-partial-info-plist "${STAGING_ROOT}/IconInfo.plist" \
    --warnings \
    --notices \
    --errors
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${INFO_PLIST}" "${STAGING_APP}/Contents/Info.plist"
for locale in en zh-Hans; do
    /bin/mkdir -p "${STAGING_APP}/Contents/Resources/${locale}.lproj"
    COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc \
        "${ROOT_DIR}/Resources/${locale}.lproj/InfoPlist.strings" \
        "${STAGING_APP}/Contents/Resources/${locale}.lproj/InfoPlist.strings"
done
/bin/chmod 755 "${STAGING_APP}/Contents/MacOS/${EXECUTABLE_NAME}"
/bin/chmod 755 "${STAGING_APP}/Contents/MacOS/lpac"

/usr/bin/xattr -cr "${STAGING_APP}"
/usr/bin/codesign --force --deep --sign - "${STAGING_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${STAGING_APP}"

/bin/mkdir -p "${OUTPUT_APP:h}"
/bin/rm -rf "${OUTPUT_APP}"
COPYFILE_DISABLE=1 /usr/bin/ditto --norsrc "${STAGING_APP}" "${OUTPUT_APP}"
/usr/bin/xattr -cr "${OUTPUT_APP}"
/usr/bin/codesign --force --deep --sign - "${OUTPUT_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${OUTPUT_APP}"

print "Packaged and verified: ${OUTPUT_APP}"
