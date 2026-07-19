"""insightface 人脸检测+识别（buffalo_l，512d 归一化 embedding）。

用途：人物分组——face embedding 聚类 → subject_name（person_0/1/…）。
模型首次自动下载到 ~/.insightface/models/buffalo_l/（~330MB）。
GPU 推理换 onnxruntime-gpu + CUDAExecutionProvider。
"""
import numpy as np
from insightface.app import FaceAnalysis


class Faces:
    NAME = "buffalo_l"
    DIM = 512

    def __init__(self):
        # CPU 推理；GPU 用 providers=["CUDAExecutionProvider"] + onnxruntime-gpu
        self.app = FaceAnalysis(name=self.NAME, providers=["CPUExecutionProvider"])
        self.app.prepare(ctx_id=-1, det_size=(640, 640))

    def detect(self, img) -> list:
        """返回 [(bbox_list, embedding_bytes)]，无人脸则空。"""
        faces = self.app.get(np.array(img.convert("RGB")))
        out = []
        for f in faces:
            emb = f.normed_embedding.astype("float32").tobytes()  # 512 × 4 = 2048B
            out.append((f.bbox.tolist(), emb))
        return out
