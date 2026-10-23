#!/usr/bin/env bash
# Builds Wayward's FFmpeg: an LGPL-only, remux-only ffmpeg + ffprobe for arm64 Android.
#
# No --enable-gpl, no --enable-nonfree, no encoders, no network. yt-dlp only
# uses it to merge separate video and audio streams and to fix up HLS output, all with
# stream copy. The one decoder is FFmpeg's own AAC decoder: AAC in MPEG-TS (HLS) carries no
# reliable sample rate, so ffmpeg has to decode a few frames just to read it. The two
# programs run as separate processes; no Wayward code links them.
#
# Output: app/src/main/jniLibs/arm64-v8a/libffmpeg.so and libffprobe.so (the lib*.so names
# make Android extract them next to the app so they can be run).
#
# The exact source tarball, this script and the configure line are what the LGPL asks us
# to publish alongside the app.
set -euo pipefail

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
NDK_VERSION=30.0.16248370
API=29

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
NDK="$SDK/ndk/$NDK_VERSION"
TC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
WORK="${WORK:-$ROOT/build/ffmpeg}"
OUT="$ROOT/app/src/main/jniLibs/arm64-v8a"

[ -d "$TC" ] || { echo "NDK $NDK_VERSION not found at $NDK" >&2; exit 1; }
mkdir -p "$WORK" "$OUT"
cd "$WORK"

TARBALL="ffmpeg-$FFMPEG_VERSION.tar.xz"
[ -f "$TARBALL" ] || curl -fL -o "$TARBALL" "https://ffmpeg.org/releases/$TARBALL"
echo "$FFMPEG_SHA256  $TARBALL" | shasum -a 256 -c -
rm -rf "ffmpeg-$FFMPEG_VERSION" && tar xf "$TARBALL"
cd "ffmpeg-$FFMPEG_VERSION"

# Tools are found on PATH by name so no local folder paths end up in the binary's
# published configure line.
export PATH="$TC/bin:$PATH"
./configure \
  --prefix=/usr/local \
  --target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile \
  --cc="aarch64-linux-android$API-clang" --cxx="aarch64-linux-android$API-clang++" \
  --nm=llvm-nm --ar=llvm-ar --ranlib=llvm-ranlib --strip=llvm-strip \
  --extra-ldflags="-Wl,-z,max-page-size=16384" \
  --disable-everything --disable-autodetect --disable-network \
  --disable-doc --disable-debug --disable-ffplay \
  --enable-static --disable-shared --enable-pic --enable-small \
  --enable-ffmpeg --enable-ffprobe \
  --enable-protocol=file,pipe \
  --enable-demuxer=mov,matroska,mpegts,aac,mp3,flv,ogg,wav,concat,h264,hevc \
  --enable-muxer=mp4,mov,ipod,matroska,webm,mp3,adts,mpegts,ogg,opus,null \
  --enable-parser=h264,hevc,aac,aac_latm,mpegaudio,vp8,vp9,av1,opus,vorbis \
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe,extract_extradata,dump_extradata,null \
  --enable-decoder=aac,aac_latm \
  --enable-filter=null,anull,aresample,format,aformat,copy,acopy

make -j"$(sysctl -n hw.ncpu)"
"$TC/bin/llvm-strip" -o "$OUT/libffmpeg.so" ffmpeg
"$TC/bin/llvm-strip" -o "$OUT/libffprobe.so" ffprobe
grep -m1 FFMPEG_CONFIGURATION config.h | sed 's/^#define FFMPEG_CONFIGURATION //' > "$ROOT/tools/ffmpeg-configure.txt"
grep -m1 '#define FFMPEG_LICENSE' config.h
ls -la "$OUT"/libffmpeg.so "$OUT"/libffprobe.so
