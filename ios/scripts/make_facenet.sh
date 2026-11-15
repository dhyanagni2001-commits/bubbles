#!/bin/sh
# Builds ios/Vendor/FaceNet/FaceNet.mlpackage: FaceNet InceptionResnetV1 (VGGFace2 weights from facenet-pytorch)
# converted to CoreML. 160x160 RGB face -> 512-d L2-normalized signature. Needs uv. Vendor/ is gitignored.
set -eu
cd "$(dirname "$0")/.."
[ -d Vendor/FaceNet/FaceNet.mlpackage ] && { echo "FaceNet already present"; exit 0; }
T=$(mktemp -d)
uv venv -q -p 3.12 "$T/env"
VIRTUAL_ENV="$T/env" uv pip install -q torch==2.7.1 torchvision==0.22.1 coremltools==8.3.0 numpy==2.2.6 pillow requests tqdm
VIRTUAL_ENV="$T/env" uv pip install -q --no-deps facenet-pytorch==2.6.0
mkdir -p "$T/w" Vendor/FaceNet
curl -fL --retry 3 -o "$T/w/vggface2.pt" https://github.com/timesler/facenet-pytorch/releases/download/v2.2.9/20180402-114759-vggface2.pt
"$T/env/bin/python" -I scripts/convert_facenet.py "$T/w/vggface2.pt" Vendor/FaceNet/FaceNet.mlpackage
rm -rf "$T"
echo "FaceNet ready in ios/Vendor/FaceNet"
