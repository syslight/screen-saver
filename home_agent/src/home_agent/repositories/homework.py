from __future__ import annotations

from datetime import date
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.domain.models import (
    HomeworkEvent,
    HomeworkInspection,
    HomeworkReview,
    HomeworkSubmission,
    HomeworkTask,
    HouseholdMember,
    SubmissionAsset,
)


class HomeworkRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def members(self, household_id: str) -> list[HouseholdMember]:
        result = await self.session.scalars(
            select(HouseholdMember)
            .where(HouseholdMember.household_id == household_id)
            .order_by(HouseholdMember.created_at)
        )
        return list(result)

    async def member(self, household_id: str, member_id: str) -> HouseholdMember | None:
        result = await self.session.scalar(
            select(HouseholdMember).where(
                HouseholdMember.household_id == household_id,
                HouseholdMember.id == member_id,
            )
        )
        return result

    async def task(self, household_id: str, task_id: str) -> HomeworkTask | None:
        result = await self.session.scalar(
            select(HomeworkTask).where(
                HomeworkTask.household_id == household_id, HomeworkTask.id == task_id
            )
        )
        return result

    async def tasks(
        self,
        household_id: str,
        *,
        child_id: str | None = None,
        task_date: date | None = None,
        status: str | None = None,
    ) -> list[HomeworkTask]:
        query = select(HomeworkTask).where(HomeworkTask.household_id == household_id)
        if child_id is not None:
            query = query.where(HomeworkTask.child_id == child_id)
        if task_date is not None:
            query = query.where(HomeworkTask.task_date == task_date)
        if status is not None:
            query = query.where(HomeworkTask.status == status)
        result = await self.session.scalars(
            query.order_by(HomeworkTask.task_date.desc(), HomeworkTask.created_at.desc())
        )
        return list(result)

    async def next_attempt(self, household_id: str, task_id: str) -> int:
        current = await self.session.scalar(
            select(func.max(HomeworkSubmission.attempt_no)).where(
                HomeworkSubmission.household_id == household_id,
                HomeworkSubmission.task_id == task_id,
            )
        )
        return int(current or 0) + 1

    async def submission(self, household_id: str, submission_id: str) -> HomeworkSubmission | None:
        result = await self.session.scalar(
            select(HomeworkSubmission).where(
                HomeworkSubmission.household_id == household_id,
                HomeworkSubmission.id == submission_id,
            )
        )
        return result

    async def submissions(self, household_id: str, task_id: str) -> list[HomeworkSubmission]:
        result = await self.session.scalars(
            select(HomeworkSubmission)
            .where(
                HomeworkSubmission.household_id == household_id,
                HomeworkSubmission.task_id == task_id,
            )
            .order_by(HomeworkSubmission.attempt_no.desc())
        )
        return list(result)

    async def assets(self, household_id: str, submission_id: str) -> list[SubmissionAsset]:
        result = await self.session.scalars(
            select(SubmissionAsset)
            .where(
                SubmissionAsset.household_id == household_id,
                SubmissionAsset.submission_id == submission_id,
            )
            .order_by(SubmissionAsset.created_at)
        )
        return list(result)

    async def asset(self, household_id: str, asset_id: str) -> SubmissionAsset | None:
        result = await self.session.scalar(
            select(SubmissionAsset).where(
                SubmissionAsset.household_id == household_id, SubmissionAsset.id == asset_id
            )
        )
        return result

    async def used_asset_bytes(self, household_id: str) -> int:
        result = await self.session.scalar(
            select(func.sum(SubmissionAsset.size_bytes)).where(
                SubmissionAsset.household_id == household_id
            )
        )
        return int(result or 0)

    async def reviews(self, household_id: str, submission_id: str) -> list[HomeworkReview]:
        result = await self.session.scalars(
            select(HomeworkReview)
            .where(
                HomeworkReview.household_id == household_id,
                HomeworkReview.submission_id == submission_id,
            )
            .order_by(HomeworkReview.created_at)
        )
        return list(result)

    async def inspections(self, household_id: str, submission_id: str) -> list[HomeworkInspection]:
        result = await self.session.scalars(
            select(HomeworkInspection)
            .where(
                HomeworkInspection.household_id == household_id,
                HomeworkInspection.submission_id == submission_id,
            )
            .order_by(HomeworkInspection.created_at.desc())
        )
        return list(result)

    async def events(self, household_id: str, task_id: str) -> list[HomeworkEvent]:
        result = await self.session.scalars(
            select(HomeworkEvent)
            .where(
                HomeworkEvent.household_id == household_id,
                HomeworkEvent.task_id == task_id,
            )
            .order_by(HomeworkEvent.created_at)
        )
        return list(result)

    async def add_event(
        self,
        *,
        household_id: str,
        task_id: str,
        submission_id: str | None,
        actor_type: str,
        actor_id: str | None,
        event_type: str,
        payload: dict[str, Any] | None = None,
    ) -> HomeworkEvent:
        event = HomeworkEvent(
            household_id=household_id,
            task_id=task_id,
            submission_id=submission_id,
            actor_type=actor_type,
            actor_id=actor_id,
            event_type=event_type,
            payload_json=payload or {},
        )
        self.session.add(event)
        await self.session.flush()
        return event
