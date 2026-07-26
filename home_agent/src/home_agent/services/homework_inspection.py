from __future__ import annotations

from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.config import Settings
from home_agent.domain.models import (
    HomeworkInspection,
    HomeworkSubmission,
    HomeworkTask,
    SubmissionAsset,
    utc_now,
)
from home_agent.errors import DomainError
from home_agent.repositories.audit import AuditRepository
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.repositories.homework import HomeworkRepository
from home_agent.services.homework_inspector import (
    PROMPT_VERSION,
    InspectionResult,
    OpenAICompatibleHomeworkInspector,
)


class HomeworkInspectionService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.repository = HomeworkRepository(session)
        self.audit = AuditRepository(session)

    async def start(
        self, parent: AuthenticatedParent, submission_id: str
    ) -> tuple[HomeworkInspection, HomeworkTask, list[SubmissionAsset]]:
        if not self.settings.homework_model_enabled:
            raise DomainError(
                "homework_model_disabled", "Homework model access is disabled", status_code=409
            )
        if not OpenAICompatibleHomeworkInspector(self.settings).configured:
            raise DomainError(
                "homework_model_not_configured",
                "Homework model configuration is incomplete",
                status_code=409,
            )
        submission = await self.require_submission(parent.user.household_id, submission_id)
        if submission.status != "needs_parent_review":
            raise DomainError(
                "invalid_submission_state",
                "Only submissions awaiting parent review can be inspected",
                status_code=409,
            )
        task = await self.repository.task(parent.user.household_id, submission.task_id)
        assert task is not None
        assets = await self.repository.assets(parent.user.household_id, submission.id)
        if not assets:
            raise DomainError(
                "submission_images_required", "Submission has no images", status_code=409
            )
        inspection = HomeworkInspection(
            household_id=parent.user.household_id,
            submission_id=submission.id,
            requested_by=parent.user.id,
            status="running",
            model_name=self.settings.homework_model_name,
            prompt_version=PROMPT_VERSION,
        )
        self.session.add(inspection)
        await self.session.flush()
        await self.repository.add_event(
            household_id=parent.user.household_id,
            task_id=task.id,
            submission_id=submission.id,
            actor_type="user",
            actor_id=parent.user.id,
            event_type="homework.inspection.requested",
            payload={"modelName": inspection.model_name},
        )
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="user",
            actor_id=parent.user.id,
            action="homework.inspection.request",
            resource_type="homework_inspection",
            resource_id=inspection.id,
            payload={"submissionId": submission.id, "modelName": inspection.model_name},
        )
        return inspection, task, assets

    async def complete(
        self,
        parent: AuthenticatedParent,
        task: HomeworkTask,
        inspection: HomeworkInspection,
        result: InspectionResult,
    ) -> HomeworkInspection:
        needs_review = (
            result.image_quality != "clear"
            or result.confidence < 0.75
            or result.suggested_decision == "review"
            or any(item.confidence < 0.65 for item in result.items)
        )
        inspection.status = "needs_parent_review" if needs_review else "completed"
        inspection.image_quality = result.image_quality
        inspection.summary = result.summary
        inspection.confidence = result.confidence
        inspection.suggested_decision = result.suggested_decision
        inspection.items_json = [
            item.model_dump(by_alias=True, mode="json") for item in result.items
        ]
        inspection.error_code = None
        inspection.completed_at = utc_now()
        await self.repository.add_event(
            household_id=parent.user.household_id,
            task_id=task.id,
            submission_id=inspection.submission_id,
            actor_type="agent",
            actor_id=None,
            event_type="homework.inspection.completed",
            payload={"inspectionStatus": inspection.status, "modelName": inspection.model_name},
        )
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="agent",
            actor_id=None,
            action="homework.inspection.complete",
            resource_type="homework_inspection",
            resource_id=inspection.id,
            payload={"status": inspection.status},
        )
        await self.session.flush()
        return inspection

    async def fail(
        self,
        parent: AuthenticatedParent,
        task: HomeworkTask,
        inspection: HomeworkInspection,
        error_code: str,
    ) -> HomeworkInspection:
        inspection.status = "failed"
        inspection.error_code = error_code
        inspection.completed_at = utc_now()
        await self.repository.add_event(
            household_id=parent.user.household_id,
            task_id=task.id,
            submission_id=inspection.submission_id,
            actor_type="agent",
            actor_id=None,
            event_type="homework.inspection.failed",
            payload={"errorCode": error_code, "modelName": inspection.model_name},
        )
        await self.audit.add(
            household_id=parent.user.household_id,
            actor_type="agent",
            actor_id=None,
            action="homework.inspection.fail",
            resource_type="homework_inspection",
            resource_id=inspection.id,
            reason=error_code,
        )
        await self.session.flush()
        return inspection

    async def require_submission(self, household_id: str, submission_id: str) -> HomeworkSubmission:
        submission = await self.repository.submission(household_id, submission_id)
        if submission is None:
            raise DomainError("submission_not_found", "Submission was not found", status_code=404)
        return submission
