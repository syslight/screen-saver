from __future__ import annotations

from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.domain.models import HouseholdMember, StudentDevice, StudentPairingCode


class StudentPrincipal:
    def __init__(self, device: StudentDevice, child: HouseholdMember) -> None:
        self.device = device
        self.child = child


class StudentRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def create_pairing(
        self,
        *,
        code_hash: str,
        household_id: str,
        child_id: str,
        expires_at: datetime,
        created_by: str,
    ) -> StudentPairingCode:
        pairing = StudentPairingCode(
            code_hash=code_hash,
            household_id=household_id,
            child_id=child_id,
            expires_at=expires_at,
            created_by=created_by,
        )
        self.session.add(pairing)
        await self.session.flush()
        return pairing

    async def pairing_by_hash(self, code_hash: str) -> StudentPairingCode | None:
        result = await self.session.scalar(
            select(StudentPairingCode).where(StudentPairingCode.code_hash == code_hash)
        )
        return result

    async def create_device(
        self,
        *,
        household_id: str,
        child_id: str,
        name: str,
        platform: str,
        device_key_hash: str,
    ) -> StudentDevice:
        device = StudentDevice(
            household_id=household_id,
            child_id=child_id,
            name=name,
            platform=platform,
            device_key_hash=device_key_hash,
        )
        self.session.add(device)
        await self.session.flush()
        return device

    async def principal_by_key_hash(self, key_hash: str) -> StudentPrincipal | None:
        row = (
            await self.session.execute(
                select(StudentDevice, HouseholdMember)
                .join(
                    HouseholdMember,
                    HouseholdMember.id == StudentDevice.child_id,
                )
                .where(
                    StudentDevice.device_key_hash == key_hash,
                    StudentDevice.active.is_(True),
                    HouseholdMember.active.is_(True),
                    HouseholdMember.role == "child",
                )
            )
        ).one_or_none()
        return StudentPrincipal(row[0], row[1]) if row else None

    async def principal_by_ids(self, device_id: str, child_id: str) -> StudentPrincipal | None:
        row = (
            await self.session.execute(
                select(StudentDevice, HouseholdMember)
                .join(HouseholdMember, HouseholdMember.id == StudentDevice.child_id)
                .where(
                    StudentDevice.id == device_id,
                    StudentDevice.child_id == child_id,
                    StudentDevice.active.is_(True),
                    HouseholdMember.active.is_(True),
                    HouseholdMember.role == "child",
                )
            )
        ).one_or_none()
        return StudentPrincipal(row[0], row[1]) if row else None

    async def devices(self, household_id: str) -> list[tuple[StudentDevice, HouseholdMember]]:
        rows = await self.session.execute(
            select(StudentDevice, HouseholdMember)
            .join(HouseholdMember, HouseholdMember.id == StudentDevice.child_id)
            .where(StudentDevice.household_id == household_id)
            .order_by(StudentDevice.created_at.desc())
        )
        return [(row[0], row[1]) for row in rows]

    async def device(self, household_id: str, device_id: str) -> StudentDevice | None:
        result = await self.session.scalar(
            select(StudentDevice).where(
                StudentDevice.household_id == household_id,
                StudentDevice.id == device_id,
            )
        )
        return result
