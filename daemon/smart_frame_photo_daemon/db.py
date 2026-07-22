"""共享 SQLite（与 app 共享同一文件）：schema + WAL + 迁移。

库路径与 app 的 main.dart 一致：``~/.local/share/com.example.smart_frame/photo_index.db``。
守护进程写（WAL），app 只读。
"""
import json
import sqlite3
import time
from pathlib import Path

DB_PATH = Path.home() / ".local/share/com.example.smart_frame/photo_index.db"

# photos 表：保留 app 已有列 + 守护进程新增列（embedding/质量/尺寸/时间/缩略图）
PHOTOS_SCHEMA = """
CREATE TABLE IF NOT EXISTS photos (
  id TEXT PRIMARY KEY,
  sha256 TEXT,
  phash INTEGER,
  is_photo INTEGER,
  tags TEXT,
  tagged_at INTEGER,
  hidden INTEGER DEFAULT 0,
  reason TEXT,
  indexed_at INTEGER,
  embedding_dinov2 BLOB,
  embedding_clip BLOB,
  embedding_dim INTEGER,
  quality_score REAL,
  width INTEGER,
  height INTEGER,
  taken_at INTEGER,
  thumb_path TEXT
);
"""

FACES_SCHEMA = """
CREATE TABLE IF NOT EXISTS faces (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  photo_id TEXT NOT NULL,
  subject_name TEXT,
  face_embedding BLOB,
  bbox TEXT
);
CREATE INDEX IF NOT EXISTS idx_faces_photo ON faces(photo_id);
CREATE INDEX IF NOT EXISTS idx_faces_subject ON faces(subject_name);
"""

# 旧库（阶段 1/2 建）补阶段 3 新列
NEW_COLUMNS = {
    "embedding_dinov2": "BLOB",
    "embedding_clip": "BLOB",
    "embedding_dim": "INTEGER",
    "quality_score": "REAL",
    "width": "INTEGER",
    "height": "INTEGER",
    "taken_at": "INTEGER",
    "thumb_path": "TEXT",
}


def connect(path: Path = DB_PATH) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=5.0)  # busy_timeout 5s（与 app 并发写）
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(PHOTOS_SCHEMA)
    conn.executescript(FACES_SCHEMA)
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(photos)")}
    for col, typ in NEW_COLUMNS.items():
        if col not in cols:
            conn.execute(f"ALTER TABLE photos ADD COLUMN {col} {typ}")
    conn.commit()


def mark_indexed(conn: sqlite3.Connection, photo_id: str) -> bool:
    """登记一张照片（id + indexed_at）；已存在则不动。返回是否新增。"""
    cur = conn.execute(
        "INSERT OR IGNORE INTO photos (id, indexed_at) VALUES (?, ?)",
        (photo_id, int(time.time() * 1000)),
    )
    return cur.rowcount > 0


def update_embedding(conn: sqlite3.Connection, photo_id: str,
                     *, dinov2: bytes = None, clip: bytes = None) -> None:
    """写入 embedding（阶段 B）。blob = 归一化 float32 向量的 tobytes()。"""
    if dinov2 is not None:
        conn.execute(
            "UPDATE photos SET embedding_dinov2=?, embedding_dim=768 WHERE id=?",
            (dinov2, photo_id))
    if clip is not None:
        conn.execute("UPDATE photos SET embedding_clip=? WHERE id=?", (clip, photo_id))


def update_tags(conn: sqlite3.Connection, photo_id: str, is_photo: bool, tags: str) -> None:
    """写入 VLM 标签 + is_photo（阶段 D）。"""
    conn.execute("UPDATE photos SET is_photo=?, tags=?, tagged_at=? WHERE id=?",
                 (1 if is_photo else 0, tags, int(time.time() * 1000), photo_id))


def mark_hidden(conn: sqlite3.Connection, photo_id: str, reason: str) -> None:
    """标记隐藏（非照片/重复/低质等）。"""
    conn.execute("UPDATE photos SET hidden=1, reason=? WHERE id=?", (reason, photo_id))


def add_face(conn: sqlite3.Connection, photo_id: str, embedding: bytes, bbox: list) -> None:
    """登记一张人脸（阶段 C）。"""
    conn.execute(
        "INSERT INTO faces (photo_id, face_embedding, bbox) VALUES (?,?,?)",
        (photo_id, embedding, json.dumps(bbox)),
    )


def cluster_faces(conn: sqlite3.Connection, threshold: float = 0.5) -> int:
    """对未命名 face embedding 阈值聚类（余弦 ≥ threshold 同人），赋 subject_name。

    O(n²) 连通分量，适合离线批量；全量量大时换 FAISS/sklearn。返回新聚出的人物数。
    """
    import numpy as np
    rows = conn.execute(
        "SELECT id, face_embedding FROM faces WHERE subject_name IS NULL"
    ).fetchall()
    if not rows:
        return 0
    embs = {r["id"]: np.frombuffer(r["face_embedding"], dtype="float32") for r in rows}
    ids = list(embs)
    parent = {i: i for i in ids}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for i in range(len(ids)):
        for j in range(i + 1, len(ids)):
            if float(embs[ids[i]] @ embs[ids[j]]) >= threshold:
                parent[find(ids[i])] = find(ids[j])

    groups = {}
    for i in ids:
        groups.setdefault(find(i), []).append(i)
    existing = conn.execute(
        "SELECT COUNT(DISTINCT subject_name) FROM faces WHERE subject_name IS NOT NULL"
    ).fetchone()[0]
    for idx, members in enumerate(groups.values()):
        name = f"person_{existing + idx}"
        for m in members:
            conn.execute("UPDATE faces SET subject_name=? WHERE id=?", (name, m))
    return len(groups)
