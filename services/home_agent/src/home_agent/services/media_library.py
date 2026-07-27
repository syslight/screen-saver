from __future__ import annotations

import asyncio
import base64
import json
import mimetypes
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx

from home_agent.config import Settings
from home_agent.errors import DomainError

_SUPPORTED_IMAGES = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".gif"}
_SUPPORTED_MUSIC = {".mp3", ".ogg", ".wav", ".m4a", ".aac", ".flac"}
_MOODS = {"warm", "childhood", "journey", "memory", "celebration", "calm"}
_VISIBLE_PHOTO_WHERE = (
    "COALESCE(hidden,0)=0 AND COALESCE(is_photo,1)!=0 "
    "AND lower(id) NOT LIKE '%.heic' AND lower(id) NOT LIKE '%.heif'"
)


def encode_media_id(value: str) -> str:
    return base64.urlsafe_b64encode(value.encode()).decode().rstrip("=")


def decode_media_id(value: str) -> str:
    try:
        padding = "=" * (-len(value) % 4)
        return base64.urlsafe_b64decode(value + padding).decode()
    except (ValueError, UnicodeDecodeError) as exc:
        raise DomainError("invalid_media_id", "Media id is invalid", status_code=400) from exc


@dataclass(frozen=True)
class MediaContent:
    data: bytes | None
    path: Path | None
    media_type: str
    etag: str


class MediaLibrary:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def list_photos(self, *, limit: int, offset: int) -> dict[str, Any]:
        database = self.settings.media_photo_database
        if not database.exists():
            return {"photos": [], "total": 0, "limit": limit, "offset": offset}
        with sqlite3.connect(database) as connection:
            connection.row_factory = sqlite3.Row
            where = _VISIBLE_PHOTO_WHERE
            total = connection.execute(f"SELECT COUNT(*) FROM photos WHERE {where}").fetchone()[0]
            rows = connection.execute(
                "SELECT id,taken_at,caption,location_name FROM photos "
                f"WHERE {where} ORDER BY id LIMIT ? OFFSET ?",
                (limit, offset),
            ).fetchall()
        return {
            "photos": [
                {
                    "id": encode_media_id(row["id"]),
                    "name": Path(row["id"]).name,
                    "modifiedAt": row["taken_at"],
                    "caption": row["caption"],
                    "location": row["location_name"],
                }
                for row in rows
            ],
            "total": total,
            "limit": limit,
            "offset": offset,
        }

    def describe_photo(self, media_id: str) -> dict[str, Any]:
        path = self._visible_photo_path(media_id)
        with sqlite3.connect(self.settings.media_photo_database) as connection:
            connection.row_factory = sqlite3.Row
            row = connection.execute(
                "SELECT taken_at,caption,location_name FROM photos WHERE id=?", (path,)
            ).fetchone()
            identities = [
                item[0]
                for item in connection.execute(
                    "SELECT DISTINCT p.identity_label FROM faces f "
                    "JOIN person_profiles p ON p.subject_name=f.subject_name "
                    "WHERE f.photo_id=? AND p.confirmed=1 ORDER BY p.sort_order,p.identity_label",
                    (path,),
                ).fetchall()
            ]
        assert row is not None
        return {
            "id": media_id,
            "takenAt": row["taken_at"],
            "datePrecision": "second",
            "timeIsFileModified": False,
            "location": row["location_name"],
            "caption": row["caption"],
            "identities": identities,
        }

    async def photo_content(self, media_id: str) -> MediaContent:
        value = self._visible_photo_path(media_id)
        path = Path(value)
        media_type = mimetypes.guess_type(path.name)[0] or "image/jpeg"
        if await asyncio.to_thread(path.is_file):
            stat = await asyncio.to_thread(path.stat)
            return MediaContent(None, path, media_type, f'"{stat.st_mtime_ns:x}-{stat.st_size:x}"')
        frame = self._frame_config()
        base_url = str(frame.get("nasWebdavUrl", "")).rstrip("/")
        if not base_url:
            raise DomainError("photo_unavailable", "Photo source is unavailable", status_code=503)
        try:
            async with httpx.AsyncClient(
                auth=(str(frame.get("nasWebdavUser", "")), str(frame.get("nasWebdavPassword", ""))),
                timeout=httpx.Timeout(60, connect=8),
            ) as client:
                response = await client.get(base_url + value)
                response.raise_for_status()
        except httpx.HTTPError as exc:
            raise DomainError(
                "photo_unavailable", "Photo source is unavailable", status_code=503
            ) from exc
        etag = response.headers.get("etag") or f'"{len(response.content):x}"'
        return MediaContent(response.content, None, media_type, etag)

    def select_music(
        self, *, photo_id: str | None, requested_mood: str | None
    ) -> dict[str, Any] | None:
        mood = requested_mood if requested_mood in _MOODS else self._mood_for_photo(photo_id)
        root = self.settings.media_music_dir.resolve()
        candidates = self._music_files(root / mood)
        if not candidates and mood != "warm":
            mood = "warm"
            candidates = self._music_files(root / mood)
        if not candidates:
            return None
        seed = decode_media_id(photo_id) if photo_id else mood
        track = candidates[sum(seed.encode()) % len(candidates)]
        relative = track.relative_to(root).as_posix()
        return {
            "id": encode_media_id(relative),
            "title": track.stem,
            "mood": mood,
            "contentUrl": f"/api/v1/media/music/tracks/{encode_media_id(relative)}/content",
        }

    def music_content(self, media_id: str) -> MediaContent:
        root = self.settings.media_music_dir.resolve()
        relative = Path(decode_media_id(media_id))
        path = (root / relative).resolve()
        if (
            root not in path.parents
            or path.suffix.lower() not in _SUPPORTED_MUSIC
            or not path.is_file()
        ):
            raise DomainError("track_not_found", "Music track was not found", status_code=404)
        stat = path.stat()
        media_type = mimetypes.guess_type(path.name)[0] or "audio/mpeg"
        return MediaContent(None, path, media_type, f'"{stat.st_mtime_ns:x}-{stat.st_size:x}"')

    def status(self) -> dict[str, Any]:
        database = self.settings.media_photo_database
        visible = hidden = 0
        if database.exists():
            with sqlite3.connect(database) as connection:
                visible = connection.execute(
                    f"SELECT COUNT(*) FROM photos WHERE {_VISIBLE_PHOTO_WHERE}"
                ).fetchone()[0]
                hidden = connection.execute(
                    "SELECT COUNT(*) FROM photos WHERE COALESCE(hidden,0)!=0"
                ).fetchone()[0]
        tracks = len(self._music_files(self.settings.media_music_dir.resolve(), recursive=True))
        return {"visiblePhotos": visible, "hiddenPhotos": hidden, "musicTracks": tracks}

    def _visible_photo_path(self, media_id: str) -> str:
        value = decode_media_id(media_id)
        database = self.settings.media_photo_database
        if not database.exists() or Path(value).suffix.lower() not in _SUPPORTED_IMAGES:
            raise DomainError("photo_not_found", "Photo was not found", status_code=404)
        with sqlite3.connect(database) as connection:
            row = connection.execute(
                "SELECT 1 FROM photos WHERE id=? AND COALESCE(hidden,0)=0 "
                "AND COALESCE(is_photo,1)!=0",
                (value,),
            ).fetchone()
        if row is None:
            raise DomainError("photo_not_found", "Photo was not found", status_code=404)
        return value

    def _frame_config(self) -> dict[str, Any]:
        try:
            raw = json.loads(self.settings.media_frame_config.read_text(encoding="utf-8"))
            return raw if isinstance(raw, dict) else {}
        except (OSError, json.JSONDecodeError):
            return {}

    def _mood_for_photo(self, media_id: str | None) -> str:
        if not media_id:
            return "warm"
        value = decode_media_id(media_id)
        try:
            with sqlite3.connect(self.settings.media_photo_database) as connection:
                row = connection.execute(
                    "SELECT tags,caption,location_name,taken_at FROM photos WHERE id=?", (value,)
                ).fetchone()
        except sqlite3.Error:
            return "warm"
        if row is None:
            return "warm"
        text = " ".join(str(item or "") for item in row[:3]).lower()
        mapping = {
            "celebration": ("生日", "婚礼", "春节", "聚会", "庆祝", "烟花"),
            "childhood": ("宝宝", "童年", "儿童", "孩子", "学校", "幼儿园"),
            "journey": ("旅行", "旅游", "机场", "酒店", "海边", "登山"),
            "memory": ("爷爷", "奶奶", "外公", "外婆", "老照片", "往事"),
            "calm": ("山", "湖", "海", "天空", "日落", "花", "公园", "风景"),
        }
        for mood, words in mapping.items():
            if any(word in text for word in words):
                return mood
        return "warm"

    @staticmethod
    def _music_files(path: Path, *, recursive: bool = False) -> list[Path]:
        if not path.is_dir():
            return []
        iterator = path.rglob("*") if recursive else path.glob("*")
        return sorted(
            item for item in iterator if item.is_file() and item.suffix.lower() in _SUPPORTED_MUSIC
        )
