from __future__ import annotations

from datetime import date, datetime
from typing import Any

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.domain.models import (
    HomeworkReview,
    HomeworkSubmission,
    HomeworkTask,
    HouseholdMember,
    SubmissionAsset,
    new_id,
    utc_now,
)
from home_agent.errors import DomainError
from home_agent.repositories.audit import AuditRepository
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.repositories.homework import HomeworkRepository

MEMBER_ROLES = {"parent", "child", "elder"}
TASK_STATUSES = {
    "pending",
    "in_progress",
    "needs_parent_review",
    "completed",
    "cancelled",
}
QUALITY_LEVELS = {"excellent", "good", "needs_revision", "unknown"}


class HomeworkService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repository = HomeworkRepository(session)
        self.audit = AuditRepository(session)

    async def create_member(
        self,
        parent: AuthenticatedParent,
        *,
        display_name: str,
        role: str,
        age: int | None,
    ) -> HouseholdMember:
        if role not in MEMBER_ROLES:
            raise DomainError("invalid_member_role", "Member role is invalid")
        member = HouseholdMember(
            household_id=parent.user.household_id,
            display_name=display_name,
            role=role,
            age=age,
        )
        self.session.add(member)
        try:
            await self.session.flush()
        except IntegrityError as exc:
            raise DomainError(
                "member_name_exists", "Member name already exists", status_code=409
            ) from exc
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="user",
            actor_id=parent.user.id,
            action="homework.member.create",
            resource_type="household_member",
            resource_id=member.id,
            payload={"role": role},
        )
        return member

    async def update_member(
        self,
        parent: AuthenticatedParent,
        member_id: str,
        *,
        display_name: str | None,
        age: int | None,
        active: bool | None,
        set_age: bool,
    ) -> HouseholdMember:
        member = await self.repository.member(parent.user.household_id, member_id)
        if member is None:
            raise DomainError("member_not_found", "Member was not found", status_code=404)
        if display_name is not None:
            member.display_name = display_name
        if set_age:
            member.age = age
        if active is not None:
            member.active = active
        member.updated_at = utc_now()
        try:
            await self.session.flush()
        except IntegrityError as exc:
            raise DomainError(
                "member_name_exists", "Member name already exists", status_code=409
            ) from exc
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="user",
            actor_id=parent.user.id,
            action="homework.member.update",
            resource_type="household_member",
            resource_id=member.id,
        )
        return member

    async def create_task(
        self,
        parent: AuthenticatedParent,
        *,
        child_id: str,
        title: str,
        subject: str,
        task_date: date,
        due_at: datetime | None,
        instructions: str,
        reference_answer: str | None,
        rubric: str | None,
    ) -> HomeworkTask:
        child = await self.repository.member(parent.user.household_id, child_id)
        if child is None or child.role != "child" or not child.active:
            raise DomainError("child_not_found", "Active child was not found", status_code=404)
        task = HomeworkTask(
            household_id=parent.user.household_id,
            child_id=child.id,
            title=title,
            subject=subject,
            task_date=task_date,
            due_at=due_at,
            instructions=instructions,
            reference_answer=reference_answer,
            rubric=rubric,
            created_by=parent.user.id,
        )
        self.session.add(task)
        await self.session.flush()
        await self.repository.add_event(
            household_id=parent.user.household_id,
            task_id=task.id,
            submission_id=None,
            actor_type="user",
            actor_id=parent.user.id,
            event_type="homework.task.created",
        )
        await self._audit(parent, "homework.task.create", "homework_task", task.id)
        return task

    async def update_task(
        self,
        parent: AuthenticatedParent,
        task_id: str,
        changes: dict[str, Any],
    ) -> HomeworkTask:
        task = await self.require_task(parent.user.household_id, task_id)
        if task.status not in {"pending", "in_progress"}:
            raise DomainError(
                "invalid_task_state", "Task cannot be edited in its current state", status_code=409
            )
        for key, value in changes.items():
            setattr(task, key, value)
        task.updated_at = utc_now()
        await self.repository.add_event(
            household_id=parent.user.household_id,
            task_id=task.id,
            submission_id=None,
            actor_type="user",
            actor_id=parent.user.id,
            event_type="homework.task.updated",
            payload={"fields": sorted(changes)},
        )
        await self.session.flush()
        return task

    async def start_task(self, parent: AuthenticatedParent, task_id: str) -> HomeworkTask:
        task = await self.require_task(parent.user.household_id, task_id)
        if task.status != "pending":
            raise DomainError(
                "invalid_task_state", "Only pending tasks can be started", status_code=409
            )
        task.status = "in_progress"
        task.updated_at = utc_now()
        await self._task_event(parent, task, "homework.task.started")
        return task

    async def cancel_task(self, parent: AuthenticatedParent, task_id: str) -> HomeworkTask:
        task = await self.require_task(parent.user.household_id, task_id)
        if task.status in {"completed", "cancelled"}:
            raise DomainError("invalid_task_state", "Task cannot be cancelled", status_code=409)
        task.status = "cancelled"
        task.updated_at = utc_now()
        await self._task_event(parent, task, "homework.task.cancelled")
        return task

    async def create_submission(
        self,
        parent: AuthenticatedParent,
        task_id: str,
        assets: list[dict[str, Any]],
        submission_id: str | None = None,
    ) -> HomeworkSubmission:
        task = await self.require_task(parent.user.household_id, task_id)
        if task.status not in {"pending", "in_progress"}:
            raise DomainError(
                "invalid_task_state", "Task does not accept submissions", status_code=409
            )
        submission = HomeworkSubmission(
            id=submission_id or new_id(),
            household_id=parent.user.household_id,
            task_id=task.id,
            attempt_no=await self.repository.next_attempt(parent.user.household_id, task.id),
            submitted_by=parent.user.id,
            status="needs_parent_review",
        )
        self.session.add(submission)
        await self.session.flush()
        for item in assets:
            self.session.add(
                SubmissionAsset(
                    household_id=parent.user.household_id,
                    submission_id=submission.id,
                    media_type=item["media_type"],
                    local_path=item["local_path"],
                    sha256=item["sha256"],
                    size_bytes=item["size_bytes"],
                )
            )
        task.status = "needs_parent_review"
        task.updated_at = utc_now()
        await self.repository.add_event(
            household_id=parent.user.household_id,
            task_id=task.id,
            submission_id=submission.id,
            actor_type="user",
            actor_id=parent.user.id,
            event_type="homework.submission.created",
            payload={"attemptNo": submission.attempt_no, "assetCount": len(assets)},
        )
        await self._audit(
            parent, "homework.submission.create", "homework_submission", submission.id
        )
        await self.session.flush()
        return submission

    async def review_submission(
        self,
        parent: AuthenticatedParent,
        submission_id: str,
        *,
        decision: str,
        summary: str,
        quality_level: str,
        items: list[dict[str, Any]],
    ) -> HomeworkReview:
        if decision not in {"accept", "retry"}:
            raise DomainError("invalid_review_decision", "Review decision is invalid")
        if quality_level not in QUALITY_LEVELS:
            raise DomainError("invalid_quality_level", "Quality level is invalid")
        submission = await self.repository.submission(parent.user.household_id, submission_id)
        if submission is None:
            raise DomainError("submission_not_found", "Submission was not found", status_code=404)
        if submission.status != "needs_parent_review":
            raise DomainError(
                "invalid_submission_state", "Submission was already reviewed", status_code=409
            )
        task = await self.require_task(parent.user.household_id, submission.task_id)
        if task.status != "needs_parent_review":
            raise DomainError("invalid_task_state", "Task is not awaiting review", status_code=409)
        review = HomeworkReview(
            household_id=parent.user.household_id,
            submission_id=submission.id,
            reviewer_id=parent.user.id,
            decision=decision,
            summary=summary,
            quality_level=quality_level,
            items_json=items,
        )
        self.session.add(review)
        if decision == "accept":
            submission.status = "accepted"
            task.status = "completed"
        else:
            submission.status = "changes_requested"
            task.status = "in_progress"
        task.updated_at = utc_now()
        await self.repository.add_event(
            household_id=parent.user.household_id,
            task_id=task.id,
            submission_id=submission.id,
            actor_type="user",
            actor_id=parent.user.id,
            event_type=f"homework.review.{decision}",
            payload={"qualityLevel": quality_level},
        )
        await self._audit(
            parent, "homework.submission.review", "homework_submission", submission.id
        )
        await self.session.flush()
        return review

    async def require_task(self, household_id: str, task_id: str) -> HomeworkTask:
        task = await self.repository.task(household_id, task_id)
        if task is None:
            raise DomainError("task_not_found", "Homework task was not found", status_code=404)
        return task

    async def _task_event(
        self, parent: AuthenticatedParent, task: HomeworkTask, event_type: str
    ) -> None:
        await self.repository.add_event(
            household_id=parent.user.household_id,
            task_id=task.id,
            submission_id=None,
            actor_type="user",
            actor_id=parent.user.id,
            event_type=event_type,
        )
        await self.session.flush()

    async def _audit(
        self,
        parent: AuthenticatedParent,
        action: str,
        resource_type: str,
        resource_id: str,
    ) -> None:
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="user",
            actor_id=parent.user.id,
            action=action,
            resource_type=resource_type,
            resource_id=resource_id,
        )
