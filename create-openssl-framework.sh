#!/bin/bash
source scripts/get-openssl-version.sh

set -euo pipefail

if [ ! -d lib ]; then
    echo "Please run build-libssl.sh first!"
    exit 1
fi

FWNAME=openssl
FWROOT=frameworks

if [ -d $FWROOT ]; then
    echo "Removing previous $FWNAME.framework copies"
    rm -rf $FWROOT
fi

ALL_SYSTEMS=("iPhoneOS" "iPhoneSimulator" "AppleTVOS" "AppleTVSimulator" "MacOSX" "Catalyst" "WatchOS" "WatchSimulator" "XROS" "XRSimulator")

function get_min_sdk() {
    local file=$1
    set +o pipefail
    otool -l "$file" | awk "
        /^Load command/ {
            last_command = \"\"
        }
        \$1 == \"cmd\" {
            last_command = \$2
        }
        (last_command ~ /LC_BUILD_VERSION/ && \$1 == \"minos\") ||
        (last_command ~ /^LC_VERSION_MIN_/ && \$1 == \"version\") {
            print \$2
            exit
        }
    "
    set -o pipefail
}

function get_openssl_version_from_file() {
    local opensslv=$1
    local std_version=$(awk '/define OPENSSL_VERSION_TEXT/ && !/-fips/ {print $5}' "$opensslv")
    echo $(get_openssl_version $std_version)
}

DEVELOPER=`xcode-select -print-path`
FW_EXEC_NAME="${FWNAME}.framework/${FWNAME}"
INSTALL_NAME="@rpath/${FW_EXEC_NAME}"
COMPAT_VERSION="1.0.0"
CURRENT_VERSION="1.0.0"

RX='([A-z]+)([0-9]+(\.[0-9]+)*)-([A-z0-9_]+)\.sdk'

### 1. Генерация файла PrivacyInfo.plist
create_privacy_manifest() {
    local dest_folder=$1/Resources
    mkdir -p "$dest_folder"
    cat <<EOF > "$dest_folder/PrivacyInfo.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>NSPrivacyUsageDescription</key>
        <string>Этот SDK не собирает пользовательские данные.</string>
        <key>NSUserTrackingUsageDescription</key>
        <string>Этот SDK не отслеживает пользователя.</string>
    </dict>
</plist>
EOF
    echo "Privacy Manifest added to $dest_folder"
}

### 2. Добавление подписи codesign
sign_framework() {
    local framework_path=$1
    local code_sign_identity="Apple Development: illja.by4ek@gmail.com (PHVXSKWYSU)" # Замените TEAMID и имя разработчика
    codesign -s "$code_sign_identity" --force --deep --timestamp "$framework_path"
    echo "Signed $framework_path"
}

cd bin
for TARGETDIR in `ls -d *.sdk`; do
    if [[ $TARGETDIR =~ $RX ]]; then
        PLATFORM="${BASH_REMATCH[1]}"
        SDKVERSION="${BASH_REMATCH[2]}"
        ARCH="${BASH_REMATCH[4]}"
    fi

    echo "Assembling .dylib for $PLATFORM $SDKVERSION ($ARCH)"

    MIN_SDK_VERSION=$(get_min_sdk "${TARGETDIR}/lib/libcrypto.a")
    if [[ $PLATFORM == AppleTVSimulator* ]]; then
        MIN_SDK="-platform_version tvos-simulator $MIN_SDK_VERSION $SDKVERSION"
    elif [[ $PLATFORM == AppleTV* ]]; then
        MIN_SDK="-platform_version tvos $MIN_SDK_VERSION $SDKVERSION"
    elif [[ $PLATFORM == MacOSX* ]]; then
        MIN_SDK="-platform_version macos $MIN_SDK_VERSION $SDKVERSION"
    elif [[ $PLATFORM == Catalyst* ]]; then
        MIN_SDK="-platform_version mac-catalyst $MIN_SDK_VERSION $SDKVERSION"
        PLATFORM="MacOSX"
    elif [[ $PLATFORM == iPhoneSimulator* ]]; then
        MIN_SDK="-platform_version ios-simulator $MIN_SDK_VERSION $SDKVERSION"
    elif [[ $PLATFORM == WatchOS* ]]; then
        MIN_SDK="-platform_version watchos $MIN_SDK_VERSION $SDKVERSION"
    elif [[ $PLATFORM == WatchSimulator* ]]; then
        MIN_SDK="-platform_version watchos-simulator $MIN_SDK_VERSION $SDKVERSION"
    elif [[ $PLATFORM == XRSimulator* ]]; then
        MIN_SDK="-platform_version xros-simulator $MIN_SDK_VERSION $SDKVERSION"
    elif [[ $PLATFORM == XR* ]]; then
        MIN_SDK="-platform_version xros $MIN_SDK_VERSION $SDKVERSION"
    else
        MIN_SDK="-platform_version ios $MIN_SDK_VERSION $SDKVERSION"
    fi

    CROSS_TOP="${DEVELOPER}/Platforms/${PLATFORM}.platform/Developer"
    CROSS_SDK="${PLATFORM}${SDKVERSION}.sdk"
    SDK="${CROSS_TOP}/SDKs/${CROSS_SDK}"

    TARGETOBJ="${TARGETDIR}/obj"
    rm -rf $TARGETOBJ
    mkdir $TARGETOBJ
    cd $TARGETOBJ
    ar -x ../lib/libcrypto.a
    ar -x ../lib/libssl.a
    cd ..

    ld obj/*.o \
        -dylib \
        -lSystem \
        -arch $ARCH \
        $MIN_SDK \
        -syslibroot $SDK \
        -compatibility_version $COMPAT_VERSION \
        -current_version $CURRENT_VERSION \
        -application_extension \
        -o $FWNAME.dylib
    install_name_tool -id $INSTALL_NAME $FWNAME.dylib

    cd ..
done
cd ..

for SYS in ${ALL_SYSTEMS[@]}; do
    SYSDIR="$FWROOT/$SYS"
    FWDIR="$SYSDIR/$FWNAME.framework"
    DYLIBS=(bin/${SYS}*/$FWNAME.dylib)

    if [[ ${#DYLIBS[@]} -gt 0 && -e ${DYLIBS[0]} ]]; then
        echo "Creating framework for $SYS"
        mkdir -p $FWDIR/Headers
        lipo -create ${DYLIBS[@]} -output $FWDIR/$FWNAME
        cp -r include/$FWNAME/* $FWDIR/Headers/
        cp -L assets/$SYS/Info.plist $FWDIR/Info.plist
        MIN_SDK_VERSION=$(get_min_sdk "$FWDIR/$FWNAME")
        OPENSSL_VERSION=$(get_openssl_version_from_file "$FWDIR/Headers/opensslv.h")
        sed -e "s/\\\$(MIN_SDK_VERSION)/$MIN_SDK_VERSION/g" \
            -e "s/\\\$(OPENSSL_VERSION)/$OPENSSL_VERSION/g" \
            -i '' "$FWDIR/Info.plist"
        
        # Создание Privacy Manifest
        create_privacy_manifest "$FWDIR"
        
        # Подпись фреймворка
        sign_framework "$FWDIR"
        
        echo "Created $FWDIR"
    else
        echo "Skipped framework for $SYS"
    fi
done

rm bin/*/$FWNAME.dylib

for SYS in ${ALL_SYSTEMS[@]}; do
    echo "gg $SYS"
    if [[ $SYS == "MacOSX" || $SYS == "Catalyst" ]]; then
        SYSDIR="$FWROOT/$SYS"
        FWDIR="$SYSDIR/$FWNAME.framework"
        if [[ ! -e "$FWDIR" ]]; then
            continue
        fi
        cd $FWDIR

        echo "gg"
        mkdir "Versions"
        mkdir "Versions/A"
        mkdir "Versions/A/Resources"
        mv "openssl" "Headers" "Versions/A"
        mv "Info.plist" "Versions/A/Resources"

        echo "gg 22"

        (cd "Versions" && ln -s "A" "Current")
        ln -s "Versions/Current/openssl"
        ln -s "Versions/Current/Headers"
        # ln -s "Versions/Current/Resources"

        cd ../../..
    fi
done

build_xcframework() {
    echo "Building $FWNAME.xcframework"
    local FRAMEWORKS=($FWROOT/*/$FWNAME.framework)
    local ARGS=
    for ARG in ${FRAMEWORKS[@]}; do
        ARGS+="-framework ${ARG} "
    done

    echo "Frameworks: $ARGS"

    echo
    xcodebuild -create-xcframework $ARGS -output "$FWROOT/$FWNAME.xcframework"

    echo "Signing"
    # Подпись готового XCFramework
    sign_framework "$FWROOT/$FWNAME.xcframework"
}

build_xcframework