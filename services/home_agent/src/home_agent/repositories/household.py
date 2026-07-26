from __future__ import annotations

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.domain.models import Household, Room, User


class HouseholdRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def count(self) -> int:
        return int(await self.session.scalar(select(func.count()).select_from(Household)) or 0)

    async def room(self, household_id: str, room_id: str) -> Room | None:
        result = await self.session.scalar(
            select(Room).where(
                Room.household_id == household_id, Room.id == room_id, Room.active.is_(True)
            )
        )
        return result

    async def create_parent(self, household_id: str, username: str, password_hash: str) -> User:
        user = User(
            household_id=household_id,
            username=username,
            password_hash=password_hash,
            role="parent",
        )
        self.session.add(user)
        await self.session.flush()
        return user


class BootstrapResult:
    def __init__(self, household: Household, room: Room, user: User) -> None:
        self.household = household
        self.room = room
        self.user = user
