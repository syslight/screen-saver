"""向量搜索 HTTP 服务：图相似（dinov2 cosine）+ 文本语义（CLIP cosine）。

读共享 SQLite 的 embedding 列，numpy 矩阵 cosine（embedding 已 L2 归一化，点积即 cosine）。
端口 8781。供 control_server 代理给 web 控制台。

用法：uv run python -m smart_frame_photo_daemon.search_server
"""
import json
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

import numpy as np

from .models.clip import Clip

DB_PATH = '/home/peidong/.local/share/com.example.smart_frame/photo_index.db'
PORT = 8781


def _load_column(col):
    """读 photos 的 (id, embedding_col)，返回 (ids list, np.matrix[n,d])。"""
    db = sqlite3.connect(DB_PATH)
    rows = db.execute(
        f'SELECT id, {col} FROM photos WHERE {col} IS NOT NULL').fetchall()
    db.close()
    if not rows:
        return [], np.zeros((0, 1), dtype=np.float32)
    ids = [r[0] for r in rows]
    mat = np.vstack([np.frombuffer(r[1], dtype=np.float32) for r in rows])
    return ids, mat


def _topk(sims, ids, n, exclude=None):
    """sims[i] 对 ids[i]；取 top-N，排除 exclude id。"""
    order = np.argsort(-sims)
    out = []
    for i in order:
        if ids[i] == exclude:
            continue
        out.append({'id': ids[i], 'score': round(float(sims[i]), 4)})
        if len(out) >= n:
            break
    return out


class State:
    dinov2_ids = []
    dinov2_mat = np.zeros((0, 1), dtype=np.float32)
    clip_ids = []
    clip_mat = np.zeros((0, 1), dtype=np.float32)
    clip: Clip | None = None


def init_state():
    State.dinov2_ids, State.dinov2_mat = _load_column('embedding_dinov2')
    State.clip_ids, State.clip_mat = _load_column('embedding_clip')
    State.clip = Clip()  # 加载 CLIP（text encoder，CPU 够）
    print(f'搜索就绪：dinov2 {len(State.dinov2_ids)} / clip {len(State.clip_ids)}',
          flush=True)


def search_similar(photo_id: str, n: int):
    ids, mat = State.dinov2_ids, State.dinov2_mat
    if photo_id not in ids:
        return []
    q = mat[ids.index(photo_id)]
    sims = mat @ q  # cosine（归一化）
    return _topk(sims, ids, n, exclude=photo_id)


def search_text(text: str, n: int):
    if not text or State.clip is None:
        return []
    emb_bytes = State.clip.embed_text(text)  # 512d float32 tobytes
    q = np.frombuffer(emb_bytes, dtype=np.float32)
    sims = State.clip_mat @ q
    return _topk(sims, State.clip_ids, n)


class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        self.send_response(code)
        self.send_header('content-type', 'application/json; charset=utf-8')
        self.end_headers()
        self.wfile.write(json.dumps(obj, ensure_ascii=False).encode())

    def do_GET(self):
        p = urlparse(self.path)
        q = parse_qs(p.query)
        try:
            n = int(q.get('n', ['12'])[0])
            if p.path == '/api/search/similar':
                pid = q.get('id', [''])[0]
                self._json({'results': search_similar(pid, n)})
            elif p.path == '/api/search/text':
                text = q.get('q', [''])[0]
                self._json({'results': search_text(text, n)})
            elif p.path == '/health':
                self._json({'ok': True,
                            'dinov2': len(State.dinov2_ids),
                            'clip': len(State.clip_ids)})
            else:
                self._json({'error': 'not found'}, 404)
        except Exception as e:
            self._json({'error': str(e)}, 500)

    def log_message(self, *args):
        pass  # 静默（日志走 stdout print）


def main():
    init_state()
    print(f'向量搜索服务监听 :{PORT}', flush=True)
    ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()


if __name__ == '__main__':
    main()
