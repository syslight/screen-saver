from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.config import Settings
from home_agent.domain.models import AuthSession, Household, Room, User, new_id, utc_now
from home_agent.errors import DomainError
from home_agent.repositories.audit import AuditRepository
from home_agent.repositories.auth import AuthenticatedParent, AuthRepository
from home_agent.repositories.household import BootstrapResult, HouseholdRepository
from home_agent.security import credential_hash, hash_password, random_credential, verify_password


def _utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value


class AuthService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.auth = AuthRepository(session)
        self.households = HouseholdRepository(session)
        self.audit = AuditRepository(session)

    async def bootstrap(
        self, household_name: str, timezone_name: str, username: str, password: str
    ) -> BootstrapResult:
        if await self.households.count() != 0:
            raise DomainError(
                "already_bootstrapped",
                "The household has already been initialized",
                status_code=409,
            )
        household = Household(id=new_id(), name=household_name, timezone=timezone_name)
        room = Room(id=new_id(), household_id=household.id, name="客厅")
        user = User(
            id=new_id(),
            household_id=household.id,
            username=username,
            password_hash=hash_password(password),
            role="parent",
        )
        self.session.add_all([household, room, user])
        try:
            await self.session.flush()
        except IntegrityError as exc:
            raise DomainError(
                "already_bootstrapped",
                "The household has already been initialized",
                status_code=409,
            ) from exc
        await self.audit.add(
            household_id=household.id,
            actor_type="user",
            actor_id=user.id,
            action="household.bootstrap",
            resource_type="household",
            resource_id=household.id,
        )
        return BootstrapResult(household, room, user)

    async def login(self, username: str, password: str) -> tuple[str, AuthSession, User]:
        user = await self.auth.user_by_username(username)
        if user is None or not verify_password(user.password_hash, password):
            raise DomainError(
                "invalid_credentials", "Invalid username or password", status_code=401
            )
        token = random_credential()
        expires_at = utc_now() + timedelta(seconds=self.settings.session_ttl_seconds)
        auth_session = await self.auth.create_session(user.id, credential_hash(token), expires_at)
        await self.audit.add(
            household_id=user.household_id,
            actor_type="user",
            actor_id=user.id,
            action="auth.login",
            resource_type="session",
            resource_id=auth_session.id,
        )
        return token, auth_session, user

    async def authenticate(self, token: str) -> AuthenticatedParent:
        row = await self.auth.session_with_user(credential_hash(token))
        if row is None:
            raise DomainError("invalid_session", "Authentication is required", status_code=401)
        auth_session, user = row
        if auth_session.revoked_at is not None or _utc(auth_session.expires_at) <= utc_now():
            raise DomainError("invalid_session", "Authentication is required", status_code=401)
        if user.role != "parent":
            raise DomainError("forbidden", "Parent permission is required", status_code=403)
        return AuthenticatedParent(auth_session, user)

    async def authenticate_parent_ids(self, session_id: str, user_id: str) -> AuthenticatedParent:
        row = await self.auth.session_with_user_by_ids(session_id, user_id)
        if row is None:
            raise DomainError("invalid_session", "Authentication is required", status_code=401)
        auth_session, user = row
        if auth_session.revoked_at is not None or _utc(auth_session.expires_at) <= utc_now():
            raise DomainError("invalid_session", "Authentication is required", status_code=401)
        if user.role != "parent":
            raise DomainError("forbidden", "Parent permission is required", status_code=403)
        return AuthenticatedParent(auth_session, user)

    async def logout(self, parent: AuthenticatedParent) -> None:
        parent.session.revoked_at = utc_now()
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="user",
            actor_id=parent.user.id,
            action="auth.logout",
            resource_type="session",
            resource_id=parent.session.id,
        )
        await self.session.flush()

    async def create_parent(
        self, parent: AuthenticatedParent, username: str, password: str
    ) -> User:
        try:
            user = await self.households.create_parent(
                parent.user.household_id, username, hash_password(password)
            )
        except IntegrityError as exc:
            raise DomainError(
                "username_exists", "Username already exists", status_code=409
            ) from exc
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="user",
            actor_id=parent.user.id,
            action="user.create",
            resource_type="user",
            resource_id=user.id,
            payload={"role": "parent"},
        )
        return user
