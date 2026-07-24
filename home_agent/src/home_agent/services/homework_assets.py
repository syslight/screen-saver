from __future__ import annotations

import asyncio
import hashlib
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

from fastapi import UploadFile
from PIL import Image, UnidentifiedImageError

from home_agent.config import Settings
from home_agent.errors import DomainError

_IMAGE_FORMATS = {
    "JPEG": ("image/jpeg", ".jpg"),
    "PNG": ("image/png", ".png"),
    "WEBP": ("image/webp", ".webp"),
}


@dataclass
class StagedAsset:
    temp_path: Path
    media_type: str
    extension: str
    sha256: str
    size_bytes: int


class HomeworkAssetService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.root = settings.data_dir / "homework"
        self.temp_dir = self.root / "tmp"
        self.asset_dir = self.root / "assets"

    async def stage(self, files: list[UploadFile], *, used_bytes: int) -> list[StagedAsset]:
        if not files:
            raise DomainError("images_required", "At least one homework image is required")
        if len(files) > self.settings.homework_max_files_per_submission:
            raise DomainError(
                "too_many_images",
                f"At most {self.settings.homework_max_files_per_submission} images are allowed",
                status_code=413,
            )
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        staged: list[StagedAsset] = []
        try:
            for upload in files:
                staged.append(await self._stage_one(upload))
            new_bytes = sum(item.size_bytes for item in staged)
            if used_bytes + new_bytes > self.settings.homework_quota_bytes:
                raise DomainError(
                    "homework_quota_exceeded", "Homework image quota is exceeded", status_code=413
                )
            return staged
        except Exception:
            await self.cleanup_staged(staged)
            raise

    async def _stage_one(self, upload: UploadFile) -> StagedAsset:
        descriptor, raw_path = tempfile.mkstemp(prefix="upload-", suffix=".part", dir=self.temp_dir)
        path = Path(raw_path)
        digest = hashlib.sha256()
        size = 0
        try:
            with os.fdopen(descriptor, "wb") as target:
                while chunk := await upload.read(1024 * 1024):
                    size += len(chunk)
                    if size > self.settings.homework_max_file_bytes:
                        raise DomainError(
                            "image_too_large",
                            "Each image must be at most "
                            f"{self.settings.homework_max_file_bytes} bytes",
                            status_code=413,
                        )
                    digest.update(chunk)
                    await asyncio.to_thread(target.write, chunk)
            media_type, extension = await asyncio.to_thread(self._inspect_image, path)
            return StagedAsset(path, media_type, extension, digest.hexdigest(), size)
        except Exception:
            await asyncio.to_thread(path.unlink, missing_ok=True)
            raise

    @staticmethod
    def _inspect_image(path: Path) -> tuple[str, str]:
        try:
            with Image.open(path) as image:
                image_format = image.format
                image.verify()
        except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as exc:
            raise DomainError("invalid_image", "Uploaded file is not a valid image") from exc
        result = _IMAGE_FORMATS.get(image_format or "")
        if result is None:
            raise DomainError("unsupported_image_type", "Only JPEG, PNG and WebP are accepted")
        return result

    async def finalize(
        self,
        staged: list[StagedAsset],
        *,
        household_id: str,
        submission_id: str,
    ) -> list[dict[str, object]]:
        directory = self.asset_dir / household_id / submission_id
        directory.mkdir(parents=True, exist_ok=True)
        finalized: list[dict[str, object]] = []
        try:
            for item in staged:
                target = directory / f"{uuid4()}{item.extension}"
                await asyncio.to_thread(item.temp_path.replace, target)
                relative = target.relative_to(self.settings.data_dir).as_posix()
                finalized.append(
                    {
                        "media_type": item.media_type,
                        "local_path": relative,
                        "sha256": item.sha256,
                        "size_bytes": item.size_bytes,
                        "absolute_path": target,
                    }
                )
            return finalized
        except Exception:
            await self.cleanup_finalized(finalized)
            raise

    async def cleanup_staged(self, staged: list[StagedAsset]) -> None:
        for item in staged:
            await asyncio.to_thread(item.temp_path.unlink, missing_ok=True)

    async def cleanup_finalized(self, finalized: list[dict[str, object]]) -> None:
        for item in finalized:
            path = item.get("absolute_path")
            if isinstance(path, Path):
                await asyncio.to_thread(path.unlink, missing_ok=True)

    def resolve(self, local_path: str) -> Path:
        candidate = (self.settings.data_dir / local_path).resolve()
        root = self.asset_dir.resolve()
        if not candidate.is_relative_to(root) or not candidate.is_file():
            raise DomainError("asset_not_found", "Homework image was not found", status_code=404)
        return candidate
