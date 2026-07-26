from __future__ import annotations

from datetime import UTC, datetime, timedelta

from sqlalchemy import update
from sqlalchemy.engine import CursorResult
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.config import Settings
from home_agent.domain.models import StudentDevice, StudentPairingCode, utc_now
from home_agent.errors import DomainError
from home_agent.repositories.audit import AuditRepository
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.repositories.homework import HomeworkRepository
from home_agent.repositories.student import StudentPrincipal, StudentRepository
from home_agent.security import credential_hash, random_credential, random_human_code


def _utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value


class StudentService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.students = StudentRepository(session)
        self.homework = HomeworkRepository(session)
        self.audit = AuditRepository(session)

    async def create_pairing_code(
        self, parent: AuthenticatedParent, child_id: str
    ) -> tuple[str, StudentPairingCode]:
        child = await self.homework.member(parent.user.household_id, child_id)
        if child is None or child.role != "child" or not child.active:
            raise DomainError("child_not_found", "Active child was not found", status_code=404)
        code = random_human_code()
        pairing = await self.students.create_pairing(
            code_hash=credential_hash(code),
            household_id=parent.user.household_id,
            child_id=child.id,
            expires_at=utc_now() + timedelta(seconds=self.settings.pairing_ttl_seconds),
            created_by=parent.user.id,
        )
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="user",
            actor_id=parent.user.id,
            action="student.pairing_code.create",
            resource_type="household_member",
            resource_id=child.id,
        )
        return code, pairing

    async def pair(self, code: str, name: str, platform: str) -> tuple[StudentDevice, str, str]:
        pairing = await self.students.pairing_by_hash(credential_hash(code))
        if pairing is None:
            raise DomainError("invalid_pairing_code", "Pairing code is invalid", status_code=401)
        now = utc_now()
        if pairing.used_at is not None:
            raise DomainError(
                "pairing_code_used", "Pairing code has already been used", status_code=409
            )
        if _utc(pairing.expires_at) <= now:
            raise DomainError("pairing_code_expired", "Pairing code has expired", status_code=410)
        child = await self.homework.member(pairing.household_id, pairing.child_id)
        if child is None or child.role != "child" or not child.active:
            raise DomainError("child_not_found", "Active child was not found", status_code=404)
        consumed = await self.session.execute(
            update(StudentPairingCode)
            .where(
                StudentPairingCode.id == pairing.id,
                StudentPairingCode.used_at.is_(None),
                StudentPairingCode.expires_at > now,
            )
            .values(used_at=now),
            execution_options={"synchronize_session": False},
        )
        if not isinstance(consumed, CursorResult) or consumed.rowcount != 1:
            raise DomainError(
                "pairing_code_used", "Pairing code has already been used", status_code=409
            )
        device_key = random_credential()
        device = await self.students.create_device(
            household_id=pairing.household_id,
            child_id=child.id,
            name=name,
            platform=platform,
            device_key_hash=credential_hash(device_key),
        )
        await self.audit.add(
            household_id=pairing.household_id,
            actor_type="student_device",
            actor_id=device.id,
            action="student.device.pair",
            resource_type="student_device",
            resource_id=device.id,
            payload={"childId": child.id, "platform": platform},
        )
        await self.session.flush()
        return device, device_key, child.display_name

    async def authenticate(self, device_key: str) -> StudentPrincipal:
        principal = await self.students.principal_by_key_hash(credential_hash(device_key))
        if principal is None:
            raise DomainError(
                "invalid_student_device", "Student device authentication failed", status_code=401
            )
        principal.device.last_seen_at = utc_now()
        await self.session.flush()
        return principal

    async def authenticate_ids(self, device_id: str, child_id: str) -> StudentPrincipal:
        principal = await self.students.principal_by_ids(device_id, child_id)
        if principal is None:
            raise DomainError(
                "invalid_student_device", "Student device authentication failed", status_code=401
            )
        principal.device.last_seen_at = utc_now()
        await self.session.flush()
        return principal

    async def revoke_device(self, parent: AuthenticatedParent, device_id: str) -> StudentDevice:
        device = await self.students.device(parent.user.household_id, device_id)
        if device is None:
            raise DomainError(
                "student_device_not_found", "Student device was not found", status_code=404
            )
        if device.active:
            device.active = False
            await self.audit.add(
                household_id=parent.user.household_id,
                actor_type="user",
                actor_id=parent.user.id,
                action="student.device.revoke",
                resource_type="student_device",
                resource_id=device.id,
                payload={"childId": device.child_id},
            )
            await self.session.flush()
        return device
