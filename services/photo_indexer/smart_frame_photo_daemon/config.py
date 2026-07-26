"""配置：读 app 的 config.json（NAS 凭据/过滤），env NAS_* 覆盖。

与 app（Dart）共享 config.json，保证守护进程与 app 看到同一批照片。
"""
import json
import os
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_PATH = Path(os.environ.get(
    "SMART_FRAME_CONFIG",
    os.path.expanduser("~/.local/share/com.example.smart_frame/config.json"),
))

# 与 app_config.dart 默认值一致
DEFAULT_KEYWORDS = ["截图", "screenshot", "屏幕快照", "收集"]


@dataclass
class FilterConfig:
    enabled: bool = True
    keywords: list = field(default_factory=lambda: list(DEFAULT_KEYWORDS))
    min_bytes: int = 30720


@dataclass
class NasConfig:
    url: str = "http://192.168.1.22:5005"
    user: str = ""
    password: str = ""
    remote_dir: str = ""


@dataclass
class VlmConfig:
    enabled: bool = False
    model: str = "minicpm-v"
    url: str = "http://localhost:11434"


@dataclass
class AppConfig:
    nas: NasConfig = field(default_factory=NasConfig)
    filter: FilterConfig = field(default_factory=FilterConfig)
    vlm: VlmConfig = field(default_factory=VlmConfig)


def load() -> AppConfig:
    """优先 env NAS_*，否则 config.json，再否则默认值。"""
    cfg = {}
    if CONFIG_PATH.exists():
        try:
            cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            cfg = {}

    nas = NasConfig(
        url=os.environ.get("NAS_URL") or cfg.get("nasWebdavUrl", NasConfig.url),
        user=os.environ.get("NAS_USER") or cfg.get("nasWebdavUser", ""),
        password=os.environ.get("NAS_PASSWORD") or cfg.get("nasWebdavPassword", ""),
        remote_dir=os.environ.get("NAS_DIR") or cfg.get("nasRemoteDir", ""),
    )
    flt = FilterConfig(
        enabled=cfg.get("nasFilterEnabled", True),
        keywords=cfg.get("nasFilterKeywords") or list(DEFAULT_KEYWORDS),
        min_bytes=cfg.get("nasFilterMinBytes", 30720),
    )
    vlm = VlmConfig(
        enabled=cfg.get("vlmEnabled", False),
        model=cfg.get("vlmModel", "minicpm-v"),
        url=cfg.get("ollamaUrl", "http://localhost:11434"),
    )
    return AppConfig(nas=nas, filter=flt, vlm=vlm)
