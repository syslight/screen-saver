"""CLIP 视觉+文本 embedding（语义检索）。

用 OpenAI CLIP ViT-B/32（transformers 标准，可靠）。MobileCLIP 是其轻快优化版，
接口一致（embed_image / embed_text），后续可替换为 open_clip 的 mobileclip 权重，
调用方无需改动。

用途：「放猫的照片」→ embed_text("猫") → 与每张 embed_image 余弦相似度排序。
"""
import torch
from PIL import Image
from transformers import CLIPModel, CLIPProcessor


class Clip:
    NAME = "openai/clip-vit-base-patch32"
    DIM = 512

    def __init__(self, device: str = None):
        self.device = device or ("cuda" if torch.cuda.is_available() else "cpu")
        self.processor = CLIPProcessor.from_pretrained(self.NAME)
        self.model = CLIPModel.from_pretrained(self.NAME).to(self.device).eval()

    @torch.inference_mode()
    def embed_image(self, img: Image.Image) -> bytes:
        inputs = self.processor(images=img.convert("RGB"), return_tensors="pt").to(self.device)
        # transformers 5.x 的 get_image_features 返回对象（非 tensor），直接走内部组件
        vision_outputs = self.model.vision_model(pixel_values=inputs["pixel_values"])
        image_embeds = self.model.visual_projection(vision_outputs[1])  # pooler_output → 512d
        image_embeds = torch.nn.functional.normalize(image_embeds, dim=-1)
        return image_embeds.squeeze(0).cpu().float().numpy().tobytes()  # 512 × 4 = 2048 bytes

    @torch.inference_mode()
    def embed_text(self, text: str) -> bytes:
        inputs = self.processor(text=text, return_tensors="pt", truncation=True, max_length=77).to(self.device)
        text_outputs = self.model.text_model(
            input_ids=inputs["input_ids"], attention_mask=inputs.get("attention_mask"))
        text_embeds = self.model.text_projection(text_outputs[1])  # pooler_output → 512d
        text_embeds = torch.nn.functional.normalize(text_embeds, dim=-1)
        return text_embeds.squeeze(0).cpu().float().numpy().tobytes()
