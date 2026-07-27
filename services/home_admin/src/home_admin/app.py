from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from starlette.background import BackgroundTask

from home_admin.config import Settings

_REQUEST_HEADERS_TO_DROP = {"connection", "content-length", "host", "transfer-encoding"}
_RESPONSE_HEADERS_TO_DROP = {
    "connection",
    "content-length",
    "transfer-encoding",
}


def create_app(
    settings: Settings | None = None,
    *,
    transport: httpx.AsyncBaseTransport | None = None,
) -> FastAPI:
    configured = settings or Settings()
    index_html = (Path(__file__).resolve().parent / "static" / "index.html").read_text(
        encoding="utf-8"
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        async with httpx.AsyncClient(
            base_url=str(configured.home_agent_url).rstrip("/"),
            timeout=configured.upstream_timeout_seconds,
            transport=transport,
        ) as client:
            app.state.home_agent = client
            yield

    app = FastAPI(title="HomeAdmin", version="0.1.0", lifespan=lifespan)
    app.state.settings = configured

    async def response_body(response: httpx.Response) -> AsyncIterator[bytes]:
        if response.is_stream_consumed:
            yield response.content
            return
        async for chunk in response.aiter_raw():
            yield chunk

    @app.get("/", response_class=HTMLResponse, include_in_schema=False)
    async def home_admin() -> HTMLResponse:
        return HTMLResponse(
            index_html,
            headers={"Cache-Control": "no-store, max-age=0", "Pragma": "no-cache"},
        )

    @app.get("/health/live")
    async def live() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/health/ready")
    async def ready(request: Request) -> JSONResponse:
        client: httpx.AsyncClient = request.app.state.home_agent
        try:
            response = await client.get("/health/ready")
            healthy = response.status_code == 200
        except httpx.HTTPError:
            healthy = False
        return JSONResponse(
            status_code=200 if healthy else 503,
            content={
                "status": "ready" if healthy else "upstream_unavailable",
                "homeAgent": healthy,
            },
        )

    @app.api_route(
        "/api/v1/{path:path}",
        methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        include_in_schema=False,
    )
    async def proxy_home_agent(path: str, request: Request) -> StreamingResponse:
        client: httpx.AsyncClient = request.app.state.home_agent
        headers = {
            name: value
            for name, value in request.headers.items()
            if name.lower() not in _REQUEST_HEADERS_TO_DROP
        }
        upstream_request = client.build_request(
            request.method,
            f"/api/v1/{path}",
            params=request.query_params,
            headers=headers,
            content=request.stream(),
        )
        try:
            upstream = await client.send(upstream_request, stream=True)
        except httpx.HTTPError:
            return StreamingResponse(
                iter([b'{"code":"home_agent_unavailable","message":"Home Agent unavailable"}']),
                status_code=502,
                media_type="application/json",
            )
        response_headers = {
            name: value
            for name, value in upstream.headers.items()
            if name.lower() not in _RESPONSE_HEADERS_TO_DROP
        }
        response_headers["Cache-Control"] = "no-store, max-age=0"
        response_headers["Pragma"] = "no-cache"
        return StreamingResponse(
            response_body(upstream),
            status_code=upstream.status_code,
            headers=response_headers,
            background=BackgroundTask(upstream.aclose),
        )

    return app


app = create_app()


def main() -> None:
    settings = Settings()
    logging.basicConfig(level=settings.log_level)
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
