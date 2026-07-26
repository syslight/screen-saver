"""dinov2 去重：cosine ≥ 阈值的相似照片，保留 size 最大，其余 hidden。

faiss IndexFlatIP（embedding 已 L2 归一化 → 内积 = cosine）。每张查最近邻，
若 ≥ 阈值 且 自己 size < 最近邻 → 标记 hidden（duplicate_similar_dinov2），
保留文件较大的代表。比 dHash 抓更多视觉相似（同图不同分辨率/连拍/轻编辑）。

用法：uv run python -m smart_frame_photo_daemon.dedup [--threshold 0.92]
"""
import argparse
import sqlite3

import faiss
import numpy as np

DB_PATH = '/home/peidong/.local/share/com.example.smart_frame/photo_index.db'


def main():
    ap = argparse.ArgumentParser(description='dinov2 去重')
    ap.add_argument('--threshold', type=float, default=0.92,
                    help='cosine 阈值（≥ 视为相似；0.92 抓强相似，0.86 更宽松）')
    args = ap.parse_args()

    db = sqlite3.connect(DB_PATH)
    rows = db.execute(
        'SELECT id, embedding_dinov2, indexed_at FROM photos '
        'WHERE embedding_dinov2 IS NOT NULL').fetchall()
    if not rows:
        print('无 dinov2 embedding，先跑 --embed'); return

    ids = [r[0] for r in rows]
    mat = np.vstack(
        [np.frombuffer(r[1], dtype=np.float32) for r in rows]).astype('float32')
    # photos 表无 size 列；用 indexed_at 选代表（早登记的保留，晚的 hidden）
    indexed = np.array([r[2] or 0 for r in rows])
    n = len(ids)
    print(f'加载 {n} 张 dinov2 embedding，阈值 {args.threshold}', flush=True)

    # faiss 内积索引（归一化向量内积 = cosine）；每张 top-2 = [自己, 最近邻]
    index = faiss.IndexFlatIP(mat.shape[1])
    index.add(mat)
    D, I = index.search(mat, 2)

    # 每张：最近邻 cosine ≥ 阈值 且 自己比最近邻小 → hidden（留大的代表）
    hidden = []
    for i in range(n):
        nearest = I[i][1]
        if nearest >= 0 and D[i][1] >= args.threshold and indexed[i] > indexed[nearest]:
            hidden.append(ids[i])

    for pid in hidden:
        db.execute(
            "UPDATE photos SET hidden=1, reason='duplicate_similar_dinov2' WHERE id=?",
            (pid,))
    db.commit()

    total = db.execute('SELECT COUNT(*) FROM photos WHERE hidden=1').fetchone()[0]
    db.close()
    print(f'新标记 {len(hidden)} 张相似为 hidden；库内 hidden 总数 {total}', flush=True)


if __name__ == '__main__':
    main()
