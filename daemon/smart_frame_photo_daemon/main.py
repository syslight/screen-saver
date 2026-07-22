"""照片守护进程入口（阶段 E：断点续传 + ``--watch`` 常驻）。

各 ``--embed/--faces/--tags`` 可组合；``_needs`` 跳过已算的列（断点续传）；
``--watch`` 循环全量 + 重扫新增，间隔 ``--interval``（默认 1h）。

用法：
  uv run python -m smart_frame_photo_daemon --embed --faces --tags             # 一遍
  uv run python -m smart_frame_photo_daemon --watch --embed --faces --tags     # 常驻
"""
import argparse
import io
import sys
import time

import httpx
from PIL import Image

from . import config, db, scanner


def _download(cfg: config.AppConfig, path: str, client: httpx.Client) -> bytes:
    resp = client.get(cfg.nas.url.rstrip("/") + path)
    resp.raise_for_status()
    return resp.content


def _needs(conn, photo_id: str, want: set) -> bool:
    """该张是否还需要处理（want ⊂ {embed, faces, tags}）。已全算则跳过。"""
    row = conn.execute(
        "SELECT embedding_dinov2, tags FROM photos WHERE id=?", (photo_id,)
    ).fetchone()
    if row is None:
        return True
    if "embed" in want and row["embedding_dinov2"] is None:
        return True
    if "tags" in want and row["tags"] is None:
        return True
    if "faces" in want:
        n = conn.execute(
            "SELECT COUNT(*) FROM faces WHERE photo_id=?", (photo_id,)).fetchone()[0]
        if n == 0:
            return True
    return False


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="smart_frame 照片守护进程")
    parser.add_argument("--once", action="store_true", help="跑一遍（默认行为）")
    parser.add_argument("--embed", action="store_true", help="dinov2 + CLIP embedding")
    parser.add_argument("--faces", action="store_true", help="insightface 人脸")
    parser.add_argument("--tags", action="store_true", help="VLM 标签 + is_photo")
    parser.add_argument("--watch", action="store_true", help="常驻：循环全量+重扫新增")
    parser.add_argument("--interval", type=int, default=3600, help="--watch 轮询间隔秒")
    parser.add_argument("--limit", type=int, default=0, help="只处理前 N 张（调试）")
    args = parser.parse_args(argv)

    cfg = config.load()
    if not cfg.nas.remote_dir:
        print("✗ nasRemoteDir 为空（config.json 或 NAS_DIR 未设）。")
        return 1

    want = set()
    if args.embed:
        want.add("embed")
    if args.faces:
        want.add("faces")
    if args.tags:
        want.add("tags")

    conn = db.connect()
    db.init_db(conn)

    dinov2 = clip = faces_model = vlm = None
    if args.embed:
        from .models.clip import Clip
        from .models.dinov2 import DinoV2
        print("加载 dinov2 + CLIP …", flush=True)
        dinov2 = DinoV2()
        clip = Clip()
        print("embedding 模型就绪", flush=True)
    if args.faces:
        from .models.faces import Faces
        print("加载 insightface buffalo_l …", flush=True)
        faces_model = Faces()
        print("insightface 就绪", flush=True)
    if args.tags:
        from .models.vlm import Vlm
        print(f"VLM: {cfg.vlm.model} @ {cfg.vlm.url}", flush=True)
        vlm = Vlm(url=cfg.vlm.url, model=cfg.vlm.model)

    round_n = 0
    while True:
        round_n += 1
        print(f"\n=== 第 {round_n} 轮 ===", flush=True)
        refs, filtered = scanner.list_photos(cfg)
        print(f"可播放 {len(refs)}（过滤 {filtered}）", flush=True)
        if args.limit:
            refs = refs[: args.limit]

        todo = [r for r in refs if (not want) or _needs(conn, r.path, want)]
        print(f"待处理 {len(todo)} / 总 {len(refs)}", flush=True)

        n_ok = 0
        with httpx.Client(auth=(cfg.nas.user, cfg.nas.password),
                          timeout=httpx.Timeout(120.0, connect=8.0)) as client:
            for i, ref in enumerate(todo):
                db.mark_indexed(conn, ref.path)
                try:
                    data = _download(cfg, ref.path, client)
                    img = Image.open(io.BytesIO(data))
                except Exception as e:
                    print(f"  ! 下载失败 {ref.path[-40:]}: {e}", flush=True)
                    continue
                if "embed" in want:
                    updates = {}
                    try:
                        updates["dinov2"] = dinov2.embed(img)
                    except Exception as e:
                        print(f"  ! dinov2: {e}", flush=True)
                    try:
                        updates["clip"] = clip.embed_image(img)
                    except Exception as e:
                        print(f"  ! clip: {e}", flush=True)
                    if updates:
                        db.update_embedding(conn, ref.path, **updates)
                if "faces" in want and faces_model is not None:
                    try:
                        for bbox, emb in faces_model.detect(img):
                            db.add_face(conn, ref.path, emb, bbox)
                    except Exception as e:
                        print(f"  ! faces: {e}", flush=True)
                if "tags" in want and vlm is not None:
                    try:
                        is_photo, tags = vlm.tag(img)
                        db.update_tags(conn, ref.path, is_photo, tags)
                        if not is_photo:
                            db.mark_hidden(conn, ref.path, "not_photo")
                    except Exception as e:
                        print(f"  ! vlm: {e}", flush=True)
                n_ok += 1
                if (i + 1) % 5 == 0:
                    conn.commit()
                    print(f"  进度 {i+1}/{len(todo)}", flush=True)
        conn.commit()
        if "faces" in want:
            new_persons = db.cluster_faces(conn)
            conn.commit()
            print(f"人脸聚类：{new_persons} 新人物", flush=True)
        print(f"第 {round_n} 轮完成：处理 {n_ok}", flush=True)

        if not args.watch:
            break
        print(f"休眠 {args.interval}s 后下一轮 …", flush=True)
        time.sleep(args.interval)

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
