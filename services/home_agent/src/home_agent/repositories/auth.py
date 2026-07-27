from __future__ import annotations

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.domain.models import AuthSession, ParentEnrollmentCode, User


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
        self,
        user_id: str,
        token_hash: str,
        expires_at: datetime,
        *,
        client_name: str | None = None,
        platform: str | None = None,
    ) -> AuthSession:
        auth_session = AuthSession(
            user_id=user_id,
            token_hash=token_hash,
            expires_at=expires_at,
            client_name=client_name,
            platform=platform,
        )
        self.session.add(auth_session)
        await self.session.flush()
        return auth_session

    async def create_parent_enrollment(
        self,
        *,
        code_hash: str,
        household_id: str,
        user_id: str,
        expires_at: datetime,
        created_by: str,
    ) -> ParentEnrollmentCode:
        enrollment = ParentEnrollmentCode(
            code_hash=code_hash,
            household_id=household_id,
            user_id=user_id,
            expires_at=expires_at,
            created_by=created_by,
        )
        self.session.add(enrollment)
        await self.session.flush()
        return enrollment

    async def parent_enrollment_by_hash(self, code_hash: str) -> ParentEnrollmentCode | None:
        result = await self.session.scalar(
            select(ParentEnrollmentCode).where(ParentEnrollmentCode.code_hash == code_hash)
        )
        return result

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
