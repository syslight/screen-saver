"""NAS WebDAV 递归列目录（httpx PROPFIND），复刻 app 的过滤规则。

不用 webdavclient3——它对群晖 WebDAV 的 PROPFIND（尾斜杠）返回 403。
这里手写 PROPFIND + 正则解析 multistatus，与 app 的 dart webdav_client / 诊断
脚本同一请求方式，已知可用。

关键：``id`` = WebDAV 返回的完整 path，与 app 的 ``NasPhotoRef.path`` / ``PhotoItem.id``
完全一致——否则守护进程写库的 id 与 app 的 setHidden/playable 对不上。
"""
import re
from dataclasses import dataclass
from urllib.parse import unquote, urlparse
from xml.sax.saxutils import unescape

import httpx

from .config import AppConfig

# 与 photo_service.dart 的 imageExts ∪ heicExts 一致
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif", ".heic", ".heif"}

SCREENSHOT_PATTERNS = [
    re.compile(r"^Screenshot[_ -]", re.IGNORECASE),
    re.compile(r"^Screen Shot", re.IGNORECASE),
    re.compile(r"^screencap", re.IGNORECASE),
]

_RESPONSE_RE = re.compile(r"<(?:\w+:)?response\b[^>]*>(.*?)</(?:\w+:)?response>", re.DOTALL)
_HREF_RE = re.compile(r"<(?:\w+:)?href\b[^>]*>(.*?)</(?:\w+:)?href>", re.DOTALL)
_SIZE_RE = re.compile(r"<(?:\w+:)?getcontentlength\b[^>]*>(.*?)</(?:\w+:)?getcontentlength>", re.DOTALL)
_COLLECTION_RE = re.compile(r"<(?:\w+:)?collection\b[^>]*/?>", re.DOTALL)


@dataclass
class PhotoRef:
    path: str          # WebDAV 完整 path = id（与 app 一致）
    size: int
    mtime: str = None


def _segments(path: str) -> list:
    return [s for s in path.split("/") if s]


def _basename(path: str) -> str:
    segs = _segments(path)
    return segs[-1] if segs else path


def _ext(path: str) -> str:
    base = _basename(path)
    if "." not in base:
        return ""
    return "." + base.rsplit(".", 1)[-1].lower()


def allowed(path: str, size: int, *, enabled: bool, keywords: list, min_bytes: int) -> bool:
    """复刻 nas_filter.nasPhotoAllowed。"""
    if not enabled:
        return True
    if "@eaDir" in _segments(path):
        return False
    if min_bytes > 0 and size < min_bytes:
        return False
    lower = path.lower()
    for kw in keywords:
        if kw and kw.lower() in lower:
            return False
    base = _basename(path)
    for pat in SCREENSHOT_PATTERNS:
        if pat.search(base):
            return False
    return True


def _propfind(client: httpx.Client, full_url: str) -> str:
    resp = client.request("PROPFIND", full_url, headers={"Depth": "1"})
    resp.raise_for_status()
    return resp.text


def _parse(xml_text: str) -> list:
    """解析 multistatus，返回 [(path, is_dir, size)]。"""
    out = []
    for m in _RESPONSE_RE.finditer(xml_text):
        block = m.group(1)
        href_m = _HREF_RE.search(block)
        if not href_m:
            continue
        path = unquote(unescape(href_m.group(1).strip()))
        if "://" in path:  # 少数服务器返回完整 URL
            path = urlparse(path).path
        is_dir = bool(_COLLECTION_RE.search(block))
        size_m = _SIZE_RE.search(block)
        size = int(size_m.group(1)) if size_m else 0
        out.append((path, is_dir, size))
    return out


def list_photos(cfg: AppConfig) -> tuple[list[PhotoRef], int]:
    """递归列出 remote_dir 下所有通过过滤的图片；返回 (refs, filtered_count)。"""
    base = cfg.nas.url.rstrip("/")
    refs: list[PhotoRef] = []
    filtered = 0

    with httpx.Client(auth=(cfg.nas.user, cfg.nas.password),
                      timeout=httpx.Timeout(60.0, connect=8.0)) as client:
        def walk(dir_path: str):
            nonlocal filtered
            try:
                xml_text = _propfind(client, base + dir_path)
            except Exception as e:
                print(f"  ! PROPFIND 失败 {dir_path}: {e}", flush=True)
                return
            for path, is_dir, size in _parse(xml_text):
                # 跳过目录自身（第一项 href 通常等于 dir_path）
                if path.rstrip("/") == dir_path.rstrip("/"):
                    continue
                if "@eaDir" in _segments(path):
                    filtered += 1
                    continue
                if is_dir:
                    walk(path)
                    continue
                if _ext(path) not in IMAGE_EXTS:
                    continue
                if not allowed(path, size,
                               enabled=cfg.filter.enabled,
                               keywords=cfg.filter.keywords,
                               min_bytes=cfg.filter.min_bytes):
                    filtered += 1
                    continue
                refs.append(PhotoRef(path=path, size=size))

        walk(cfg.nas.remote_dir)
    return refs, filtered
