"""CLIP zero-shot 分类：截图/广告/meme → hidden（不靠 VLM，用已有 clip embedding）。

对每张照片，算一组「非照片」文本的 CLIP 相似度，max ≥ 阈值 → hidden。
秒级全量（复用已算的 67888 张 clip embedding），精度不如 VLM 但快；
VLM（守护进程 --tags）继续精确补充。

用法：uv run python -m smart_frame_photo_daemon.classify [--threshold 0.27]
"""
import argparse
import sqlite3

import numpy as np

from .models.clip import Clip

DB_PATH = '/home/peidong/.local/share/com.example.smart_frame/photo_index.db'

# 「非照片」文本集（CLIP zero-shot，中英双覆盖截图/广告/meme/漫画）
NEG_TEXTS = [
    'a screenshot of a phone screen',
    '手机屏幕截图',
    'a screenshot of a computer screen',
    '电脑网页截图',
    'an advertisement poster',
    '广告海报',
    'a product advertisement',
    '商品宣传图',
    'a meme image',
    '表情包',
    'a comic strip',
    '游戏截图',
]


def main():
    ap = argparse.ArgumentParser(description='CLIP zero-shot 截图/广告分类')
    ap.add_argument('--threshold', type=float, default=0.27,
                    help='CLIP cosine 阈值（≥ 判为非照片；0.27 中等，0.30 严 0.24 松）')
    args = ap.parse_args()

    clip = Clip()
    neg_mat = np.vstack(  # 文本 embedding（已归一化）
        [np.frombuffer(clip.embed_text(t), dtype=np.float32) for t in NEG_TEXTS])

    db = sqlite3.connect(DB_PATH)
    rows = db.execute(
        'SELECT id, embedding_clip FROM photos '
        'WHERE embedding_clip IS NOT NULL AND hidden=0').fetchall()
    if not rows:
        print('无 clip embedding'); return
    ids = [r[0] for r in rows]
    mat = np.vstack([np.frombuffer(r[1], dtype=np.float32) for r in rows])
    print(f'加载 {len(ids)} 张 clip embedding，阈值 {args.threshold}', flush=True)

    # 每张 vs 所有非照片文本，取 max cosine
    sims = mat @ neg_mat.T  # n × len(NEG_TEXTS)
    max_sim = sims.max(axis=1)

    hidden = [ids[i] for i in range(len(ids)) if max_sim[i] >= args.threshold]
    for pid in hidden:
        db.execute(
            "UPDATE photos SET hidden=1, reason='clip_not_photo' WHERE id=?", (pid,))
    db.commit()
    total = db.execute('SELECT COUNT(*) FROM photos WHERE hidden=1').fetchone()[0]
    db.close()
    print(f'CLIP zero-shot 标记 {len(hidden)} 张疑似截图/广告为 hidden；总 hidden {total}',
          flush=True)


if __name__ == '__main__':
    main()
