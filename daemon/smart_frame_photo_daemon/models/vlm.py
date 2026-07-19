"""VLM 标签（ollama minicpm-v）：场景标签 + is_photo 判定。

复用 app photo_index_service._vlmTag 的 prompt。图片先缩到 512 边 + jpg 70% 再
base64，减小请求体。返回 (is_photo, "标签1,标签2")。
"""
import base64
import io
import json

import httpx
from PIL import Image

PROMPT = ('判断这张图片。只返回JSON：'
          '{"is_photo": true表示真实照片(非截图/表情包/meme/文档/图标/纯色), '
          '"tags": [1-3个中文场景标签如 猫/风景/人物/食物]}')


class Vlm:
    def __init__(self, url: str = "http://localhost:11434", model: str = "minicpm-v"):
        self.url = url
        self.model = model

    def tag(self, img: Image.Image, timeout: float = 120.0) -> tuple:
        small = img.convert("RGB")
        small.thumbnail((512, 512))
        buf = io.BytesIO()
        small.save(buf, "JPEG", quality=70)
        b64 = base64.b64encode(buf.getvalue()).decode()

        resp = httpx.post(
            f"{self.url}/api/chat",
            json={
                "model": self.model,
                "stream": False,
                "format": "json",
                "messages": [{"role": "user", "content": PROMPT, "images": [b64]}],
            },
            timeout=timeout,
        )
        content = resp.json()["message"]["content"]
        parsed = json.loads(content)
        is_photo = bool(parsed.get("is_photo"))
        tags_list = parsed.get("tags") or []
        tags = ",".join(t for t in (self._clean_tag(x) for x in tags_list[:3]) if t)
        return (is_photo, tags)

    @staticmethod
    def _clean_tag(t) -> str:
        """minicpm-v 偶尔返回 {label, description} 对象而非字符串，统一取 label。"""
        if isinstance(t, dict):
            return str(t.get("label") or t.get("name") or "").strip()
        return str(t).strip()
