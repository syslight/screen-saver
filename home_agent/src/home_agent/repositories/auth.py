from __future__ import annotations

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.domain.models import AuthSession, User


class AuthRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def user_by_username(self, username: str) -> User | None:
        result = await self.session.scalar(
            select(User).where(User.username == username, User.active.is_(True))
        )
        return result

    async def user_by_id(self, household_id: str, user_id: str) -> User | None:
        result = await self.session.scalar(
            select(User).where(
                User.household_id == household_id,
                User.id == user_id,
                User.active.is_(True),
            )
        )
        return result

    async def create_session(
        self, user_id: str, token_hash: str, expires_at: datetime
    ) -> AuthSession:
        auth_session = AuthSession(user_id=user_id, token_hash=token_hash, expires_at=expires_at)
        self.session.add(auth_session)
        await self.session.flush()
        return auth_session

    async def session_with_user(self, token_hash: str) -> tuple[AuthSession, User] | None:
        row = (
            await self.session.execute(
                select(AuthSession, User)
                .join(User, User.id == AuthSession.user_id)
                .where(AuthSession.token_hash == token_hash, User.active.is_(True))
            )
        ).one_or_none()
        return (row[0], row[1]) if row else None

    async def session_with_user_by_ids(
        self, session_id: str, user_id: str
    ) -> tuple[AuthSession, User] | None:
        row = (
            await self.session.execute(
                select(AuthSession, User)
                .join(User, User.id == AuthSession.user_id)
                .where(
                    AuthSession.id == session_id,
                    AuthSession.user_id == user_id,
                    User.active.is_(True),
                )
            )
        ).one_or_none()
        return (row[0], row[1]) if row else None


class AuthenticatedParent:
    def __init__(self, session: AuthSession, user: User) -> None:
        self.session = session
        self.user = user
