from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import uuid4

import uvicorn
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from home_agent.api import audit, auth, households, nodes, websocket
from home_agent.config import Settings
from home_agent.db import create_engine, create_session_factory, upgrade_database
from home_agent.errors import DomainError
from home_agent.services.node_registry import NodeRegistry
from home_agent.services.rate_limit import InMemoryRateLimiter


def _error_body(request: Request, code: str, message: str, details: object) -> dict[str, object]:
    return {
        "code": code,
        "message": message,
        "details": details,
        "requestId": request.state.request_id,
    }


def create_app(settings: Settings | None = None) -> FastAPI:
    configured = settings or Settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        await upgrade_database(configured)
        engine = create_engine(configured.database_url)
        app.state.engine = engine
        app.state.session_factory = create_session_factory(engine)
        app.state.ready = True
        try:
            yield
        finally:
            app.state.ready = False
            await engine.dispose()

    app = FastAPI(title="Family Home Agent", version="0.1.0", lifespan=lifespan)
    app.state.settings = configured
    app.state.ready = False
    app.state.node_registry = NodeRegistry()
    app.state.login_limiter = InMemoryRateLimiter(limit=10)
    app.state.pairing_limiter = InMemoryRateLimiter(limit=20)

    @app.middleware("http")
    async def request_id_middleware(request: Request, call_next: object) -> object:
        request.state.request_id = str(uuid4())
        response = await call_next(request)  # type: ignore[operator]
        response.headers["X-Request-Id"] = request.state.request_id
        return response

    @app.exception_handler(DomainError)
    async def domain_error_handler(request: Request, exc: DomainError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content=_error_body(request, exc.code, exc.message, exc.details),
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        return JSONResponse(
            status_code=422,
            content=_error_body(
                request,
                "validation_error",
                "Request validation failed",
                {
                    "errors": [
                        {key: value for key, value in error.items() if key != "ctx"}
                        for error in exc.errors()
                    ]
                },
            ),
        )

    @app.get("/health/live")
    async def live() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/health/ready")
    async def ready(request: Request) -> JSONResponse:
        status = 200 if request.app.state.ready else 503
        return JSONResponse(
            status_code=status, content={"status": "ready" if status == 200 else "starting"}
        )

    app.include_router(auth.router)
    app.include_router(households.router)
    app.include_router(nodes.router)
    app.include_router(audit.router)
    app.include_router(websocket.router)
    return app


app = create_app()


def main() -> None:
    settings = Settings()
    logging.basicConfig(level=settings.log_level)
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
