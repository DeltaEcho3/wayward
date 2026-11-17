#!/usr/bin/env bash
# Builds Wayward's FFmpeg: an LGPL-only, remux-only ffmpeg + ffprobe for arm64 Android.
#
# No --enable-gpl, no --enable-nonfree, no encoders, no network. yt-dlp only
# uses it to merge separate video and audio streams and to fix up HLS output, all with
# stream copy. The one decoder is FFmpeg's own AAC decoder: AAC in MPEG-TS (HLS) carries no
# reliable sample rate, so ffmpeg has to decode a few frames just to read it. The two
# programs run as separate processes; no Wayward code links them.
#
# FFmpeg's libraries are built once, as shared libraries, and the two programs are small
# executables linked to them, so the code both use is shipped once and not inside each.
#
# Output, in app/src/main/jniLibs/arm64-v8a: libffmpeg.so and libffprobe.so (the programs; the
# lib*.so names make Android pack them with the app's native libraries so they can be run), and
# FFmpeg's libraries libavutil.so, libswresample.so, libswscale.so, libavcodec.so,
# libavformat.so, libavfilter.so and libavdevice.so. Each finds the others in its own folder ($ORIGIN).
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
  --extra-ldflags="-Wl,-z,max-page-size=16384 -Wl,-rpath,XORIGIN" \
  --disable-everything --disable-autodetect --disable-network \
  --disable-doc --disable-debug --disable-ffplay \
  --disable-static --enable-shared --enable-pic --enable-small \
  --enable-ffmpeg --enable-ffprobe \
  --enable-protocol=file,pipe \
  --enable-demuxer=mov,matroska,mpegts,aac,mp3,flv,ogg,wav,concat,h264,hevc \
  --enable-muxer=mp4,mov,ipod,matroska,webm,mp3,adts,mpegts,ogg,opus,null \
  --enable-parser=h264,hevc,aac,aac_latm,mpegaudio,vp8,vp9,av1,opus,vorbis \
  --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe,extract_extradata,dump_extradata,null \
  --enable-decoder=aac,aac_latm \
  --enable-filter=null,anull,aresample,format,aformat,copy,acopy

make -j"$(sysctl -n hw.ncpu)"

# The libraries FFmpeg's build made, in the order it links them; a new one stops the script.
LIBS="avutil swresample swscale avcodec avformat avfilter avdevice"
built=$(ls lib*/lib*.so | xargs -n1 basename | sort | tr '\n' ' ')
want=$(for l in $LIBS; do echo "lib$l.so"; done | sort | tr '\n' ' ')
[ "$built" = "$want" ] || { echo "FFmpeg built [$built], this script packs [$want]" >&2; exit 1; }

"$TC/bin/llvm-strip" -o "$OUT/libffmpeg.so" ffmpeg
"$TC/bin/llvm-strip" -o "$OUT/libffprobe.so" ffprobe
for l in $LIBS; do "$TC/bin/llvm-strip" --strip-unneeded -o "$OUT/lib$l.so" "lib$l/lib$l.so"; done
# Where each looks for the libraries it needs: its own folder. Written XORIGIN at link time, because $ORIGIN does
# not get through configure, make and the shell whole; the two are the same length. Only the run path's own text
# is changed (it stands alone between two zero bytes): the configure line inside the programs keeps XORIGIN, as
# tools/ffmpeg-configure.txt has it.
for f in "$OUT/libffmpeg.so" "$OUT/libffprobe.so" $(for l in $LIBS; do echo "$OUT/lib$l.so"; done); do
  python3 -I -c '
import sys
path = sys.argv[1]
data = open(path, "rb").read()
if data.count(b"\0XORIGIN\0") != 1:
    sys.exit(path + ": expected one XORIGIN run path, found %d" % data.count(b"\0XORIGIN\0"))
open(path, "wb").write(data.replace(b"\0XORIGIN\0", b"\0$ORIGIN\0"))
' "$f"
  "$TC/bin/llvm-readelf" -d "$f" | grep -q 'RUNPATH.*\[\$ORIGIN\]' || { echo "$f: run path not set" >&2; exit 1; }
done
grep -m1 FFMPEG_CONFIGURATION config.h | sed 's/^#define FFMPEG_CONFIGURATION //' > "$ROOT/tools/ffmpeg-configure.txt"
grep -m1 '#define FFMPEG_LICENSE' config.h
ls -la "$OUT"/libffmpeg.so "$OUT"/libffprobe.so $(for l in $LIBS; do echo "$OUT/lib$l.so"; done)
