"""dinov2-base 视觉 embedding（768d，L2 归一化）。

用途：视觉相似度（去重比 dHash 强）、聚类、检索。余弦相似度 = 归一化向量内积。
模型来自 HuggingFace facebook/dinov2-base（~350MB，首次自动下载）。
"""
import torch
from PIL import Image
from transformers import AutoImageProcessor, AutoModel


class DinoV2:
    NAME = "facebook/dinov2-base"
    DIM = 768

    def __init__(self, device: str = None):
        self.device = device or ("cuda" if torch.cuda.is_available() else "cpu")
        self.processor = AutoImageProcessor.from_pretrained(self.NAME)
        self.model = AutoModel.from_pretrained(self.NAME).to(self.device).eval()

    @torch.inference_mode()
    def embed(self, img: Image.Image) -> bytes:
        inputs = self.processor(images=img.convert("RGB"), return_tensors="pt").to(self.device)
        out = self.model(**inputs)
        cls = out.last_hidden_state[:, 0]              # CLS token (1, 768)
        cls = torch.nn.functional.normalize(cls, dim=-1)
        return cls.squeeze(0).cpu().float().numpy().tobytes()  # 768 × 4 = 3072 bytes
