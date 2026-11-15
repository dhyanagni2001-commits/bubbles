#!/bin/sh
# Downloads Google's prebuilt MediaPipe Tasks (Vision + Common) and the BlazeFace model into ios/Vendor.
# Same artifacts the MediaPipeTasksVision 1.0.1 CocoaPod uses; no CocoaPods needed. Vendor/ is gitignored.
set -eu
cd "$(dirname "$0")/.."
V=Vendor/MediaPipe
[ -d "$V/MediaPipeTasksVision.xcframework" ] && [ -f "$V/blaze_face_short_range.tflite" ] && { echo "MediaPipe already present"; exit 0; }
rm -rf "$V"; mkdir -p "$V/tmp"
curl -fL --retry 3 -o "$V/tmp/vision.tgz" https://dl.google.com/cpdc/20260727-225049/MediaPipeTasksVision-1.0.0.tar.gz
curl -fL --retry 3 -o "$V/tmp/common.tgz" https://dl.google.com/cpdc/20260727-225047/MediaPipeTasksCommon-1.0.0.tar.gz
mkdir -p "$V/tmp/vision" "$V/tmp/common"
tar -xzf "$V/tmp/vision.tgz" -C "$V/tmp/vision"
tar -xzf "$V/tmp/common.tgz" -C "$V/tmp/common"
mv "$(find "$V/tmp/vision" -name MediaPipeTasksVision.xcframework -maxdepth 4 | head -1)" "$V/"
mv "$(find "$V/tmp/common" -name MediaPipeTasksCommon.xcframework -maxdepth 4 | head -1)" "$V/"
mv "$(find "$V/tmp/common" -name graph_libraries -type d -maxdepth 4 | head -1)" "$V/graph_libraries"
curl -fL --retry 3 -o "$V/blaze_face_short_range.tflite" \
  https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/latest/blaze_face_short_range.tflite
rm -rf "$V/tmp"
echo "MediaPipe ready in ios/$V"
