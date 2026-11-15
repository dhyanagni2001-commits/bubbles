import sys, torch, coremltools as ct, numpy as np
from facenet_pytorch.models.inception_resnet_v1 import InceptionResnetV1
w = sys.argv[1]; out = sys.argv[2]
m = InceptionResnetV1(pretrained=None, classify=False, num_classes=8631)
sd = torch.load(w, map_location="cpu", weights_only=True)
sd = {k: v for k, v in sd.items() if not k.startswith("logits")}
missing = m.load_state_dict(sd, strict=False); print("missing", missing.missing_keys[:5], "unexpected", missing.unexpected_keys[:5])
m.eval()
x = torch.rand(1, 3, 160, 160)
t = torch.jit.trace(m, x)
ml = ct.convert(t, inputs=[ct.ImageType(name="face", shape=(1, 3, 160, 160), scale=1/128.0, bias=[-127.5/128]*3, color_layout=ct.colorlayout.RGB)],
                outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
ml.short_description = "FaceNet InceptionResnetV1 (VGGFace2). 160x160 RGB face -> L2-normalized 512-d embedding."
ml.save(out)
# sanity: CoreML vs torch on a random image
from PIL import Image
img = (np.random.rand(160,160,3)*255).astype(np.uint8)
ref = m(torch.tensor((img.astype(np.float32)-127.5)/128).permute(2,0,1)[None]).detach().numpy()[0]
got = np.array(ml.predict({"face": Image.fromarray(img)})["embedding"]).reshape(-1)
print("cos(torch, coreml) =", float(np.dot(ref, got)/np.linalg.norm(ref)/np.linalg.norm(got)), "norm", float(np.linalg.norm(got)))
