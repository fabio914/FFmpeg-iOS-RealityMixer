#!/bin/sh

ORANGE="\033[1;93m"
RED="\033[1;91m"
MAGENTA="\033[1;35m"
NOCOLOR="\033[0m"

function PrepareDependencies() {
    if [ ! `which yasm` ]
    then
        echo "${RED}Yasm not found. Trying to install with Homebrew... ${NOCOLOR}"
        brew install yasm || exit 1
    fi

    if [ ! -f gas-preprocessor.pl ]; then
        echo "${RED}gas-preprocessor.pl not found. Trying to download... ${NOCOLOR}"
        (curl -L https://github.com/libav/gas-preprocessor/raw/master/gas-preprocessor.pl \
              -o gas-preprocessor.pl \
                && chmod +x gas-preprocessor.pl) \
        || exit 1
    fi

    if [ ! -r $SOURCE ]
    then
        echo "${RED}FFmpeg source not found. Trying to download... ${NOCOLOR}"
        curl http://www.ffmpeg.org/releases/$SOURCE.tar.bz2 | tar xj \
        || exit 1
    fi
}

function FindObjectFiles() {
    local search_dir=$1
    local object_files=""

    local name=$(find $search_dir -maxdepth 3 -name "*.o")
    object_files="$object_files $name"
    echo $object_files
}

FF_VERSION="4.2"
SOURCE="ffmpeg-$FF_VERSION"
XCODE_PATH=$(xcode-select -p)
LIBRARY_NAME="FFmpeg"
LIBRARY_FILE="$LIBRARY_NAME.a"
XCFRAMEWORK_FILE="$LIBRARY_NAME.xcframework"

FFMPEG_PLATFORM="FFmpeg-iOS"
FFMPEG_BUILDS="iphoneos iphonesimulator"

CONFIGURE_FLAGS="\
                --enable-cross-compile \
                --disable-debug --disable-programs --disable-doc \
                --disable-encoders --disable-decoders --disable-protocols --disable-filters  \
                --disable-muxers --disable-bsfs --disable-indevs --disable-outdevs --disable-demuxers \
                --enable-pic \
                --enable-decoder=h264 \
                --enable-demuxer=mpegts \
                --enable-parser=h264 \
                --enable-videotoolbox"

# iPhoneOS arm64
function ConfigureForiOSArm() {
    LIBTOOL_FLAGS="\
         -syslibroot $XCODE_PATH/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk \
         -L$XCODE_PATH/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/iOSSupport/usr/lib"
    DEPLOYMENT_TARGET="14.0"
    PLATFORM="iPhoneOS"
    CFLAGS="-arch arm64 -mios-version-min=$DEPLOYMENT_TARGET -fembed-bitcode"
    EXPORT="GASPP_FIX_XCODE5=1"
}

# iPhoneSimulator x86_64
function ConfigureForiOSSimulatorIntel() {
    LIBTOOL_FLAGS="\
         -syslibroot $XCODE_PATH/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk \
         -L$XCODE_PATH/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/iOSSupport/usr/lib"
    DEPLOYMENT_TARGET="14.0"
    PLATFORM="iPhoneSimulator"
    CFLAGS="-arch x86_64 -mios-simulator-version-min=$DEPLOYMENT_TARGET"
    CONFIGURE_FLAGS="$CONFIGURE_FLAGS --disable-asm"
}

# iPhoneSimulator arm64
function ConfigureForiOSSimulatorArm() {
    LIBTOOL_FLAGS="\
         -syslibroot $XCODE_PATH/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk \
         -L$XCODE_PATH/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/iOSSupport/usr/lib"
    DEPLOYMENT_TARGET="14.0"
    PLATFORM="iPhoneSimulator"
    CFLAGS="-arch arm64 -mios-simulator-version-min=$DEPLOYMENT_TARGET"
    EXPORT="GASPP_FIX_XCODE5=1"
}

function Architectures() {
    local sdk=$1

    case $sdk in
        iphoneos)                    echo "arm64" ;;
        iphonesimulator)             echo "arm64 x86_64" ;;
    esac
}

function Configure() {
    local sdk=$1
    local arch=$2
    local option="$sdk-$arch"

    echo "${ORANGE}Configuring for: $option"

    case $option in
        "iphoneos-arm64")                    ConfigureForiOSArm ;;
        "iphonesimulator-arm64")             ConfigureForiOSSimulatorArm ;;
        "iphonesimulator-x86_64")            ConfigureForiOSSimulatorIntel ;;
    esac
}

function Build() {
    local platform=$1
    local sdk=$2
    local arch=$3

    echo "${ORANGE}Building for platform: $platform, sdk: $sdk, arch: $arch ${NOCOLOR}"

    local current_dir=`pwd`
    local build_dir="$platform/$sdk/scratch/$arch"
    local thin="$current_dir/$platform/$sdk/thin"
    local prefix="$thin/$arch"

    mkdir -p "$build_dir"
    cd "$build_dir"

    local xcrun_sdk=`echo $PLATFORM | tr '[:upper:]' '[:lower:]'`
    CC="xcrun -sdk $xcrun_sdk clang"

    if [ "$arch" = "arm64" ]
    then
        AS="$current_dir/gas-preprocessor.pl -arch aarch64 -- $CC"
    else
        AS="$current_dir/gas-preprocessor.pl -- $CC"
    fi

    CXXFLAGS="$CFLAGS"
    LDFLAGS="$CFLAGS"

    TMPDIR=${TMPDIR/%\/} $current_dir/$SOURCE/configure \
        --target-os=darwin \
        --arch=$arch \
        --cc="$CC" \
        --as="$AS" \
        $CONFIGURE_FLAGS \
        --extra-cflags="$CFLAGS" \
        --extra-ldflags="$LDFLAGS" \
        --prefix="$prefix" \
    || exit 1

    make -j3 install $EXPORT || exit 1
    cd $current_dir
}

function PackageToLibrary() {
    local platform=$1
    local sdk=$2
    local arch=$3

    echo "${ORANGE}Packaging library for platform: $platform, sdk: $sdk, arch: $arch ${NOCOLOR}"

    local current_dir=`pwd`
    local build_dir="$platform/$sdk/scratch/$arch"
    local thin_dir="$current_dir/$platform/$sdk/thin/$arch"

    local object_files="$(FindObjectFiles $build_dir)"

    libtool $LIBTOOL_FLAGS \
        -static -D -arch_only $arch \
        $object_files -o "$thin_dir/$LIBRARY_FILE"
}

function CreateFat() {
    local platform=$1
    local sdk=$2
    local archs=$3
    
    echo "${ORANGE}Creating fat library for platform: $platform, sdk: $sdk, archs: $archs ${NOCOLOR}"
    local current_dir=`pwd`
    local fat_dir="$current_dir/$platform/$sdk/fat"
    local thin_libs=""

    mkdir -p "$fat_dir"

    for arch in $archs
    do
        local thin="$current_dir/$platform/$sdk/thin/$arch/$LIBRARY_FILE"
        thin_libs="$thin_libs $thin"
    done
    
    lipo -create $thin_libs -output "$fat_dir/$LIBRARY_FILE"
}

function BuildAll() {
    echo "${ORANGE}Building for platform:${MAGENTA} $FFMPEG_PLATFORM ${NOCOLOR}"

    rm -rf "$FFMPEG_PLATFORM"

    for sdk in $FFMPEG_BUILDS
    do
        local archs="$(Architectures $sdk)"

        for arch in $archs
        do
            Configure $sdk $arch
            Build $FFMPEG_PLATFORM $sdk $arch
            PackageToLibrary $FFMPEG_PLATFORM $sdk $arch
        done
        
        CreateFat $FFMPEG_PLATFORM $sdk "$archs"
    done
}

function CreateXCFramework() {
    local platform=$1
    echo "${ORANGE}Creating framework: $XCFRAMEWORK_FILE ${NOCOLOR}"

    local framework_arguments=""

    rm -rf $XCFRAMEWORK_FILE

    for sdk in $FFMPEG_BUILDS
    do
        local fat_dir="$platform/$sdk/fat"
        local archs=$(Architectures $sdk)
        local arr=($archs)
        local include_dir="$platform/$sdk/thin/${arr[0]}/include"

        framework_arguments="$framework_arguments -library $fat_dir/$LIBRARY_FILE"
        framework_arguments="$framework_arguments -headers $include_dir"
    done

    xcodebuild -create-xcframework \
        $framework_arguments \
        -output "$XCFRAMEWORK_FILE"
}

PrepareDependencies
BuildAll
CreateXCFramework $FFMPEG_PLATFORM
