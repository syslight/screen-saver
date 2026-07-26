from __future__ import annotations

from datetime import date
from typing import Any

from fastapi import APIRouter, Depends, File, Query, Request, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.api.dependencies import get_parent, get_session
from home_agent.api.schemas import (
    HomeworkAssetResponse,
    HomeworkEventResponse,
    HomeworkInspectionItemResponse,
    HomeworkInspectionResponse,
    HomeworkModelStatusResponse,
    HomeworkReviewRequest,
    HomeworkReviewResponse,
    HomeworkSubmissionResponse,
    HomeworkTaskCreate,
    HomeworkTaskResponse,
    HomeworkTaskUpdate,
    MemberCreate,
    MemberResponse,
    MemberUpdate,
)
from home_agent.domain.models import (
    HomeworkInspection,
    HomeworkReview,
    HomeworkSubmission,
    HomeworkTask,
    HouseholdMember,
    SubmissionAsset,
    new_id,
)
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.repositories.homework import HomeworkRepository
from home_agent.services.auth import AuthService
from home_agent.services.homework import TASK_STATUSES, HomeworkService
from home_agent.services.homework_assets import HomeworkAssetService
from home_agent.services.homework_inspection import HomeworkInspectionService
from home_agent.services.homework_inspector import (
    InspectionProviderError,
    OpenAICompatibleHomeworkInspector,
)

router = APIRouter(prefix="/api/v1/homework", tags=["homework"])


async def _current_parent(
    session: AsyncSession, request: Request, parent: AuthenticatedParent
) -> AuthenticatedParent:
    return await AuthService(session, request.app.state.settings).authenticate_parent_ids(
        parent.session.id, parent.user.id
    )


def _member_response(member: HouseholdMember) -> MemberResponse:
    return MemberResponse(
        id=member.id,
        display_name=member.display_name,
        role=member.role,
        age=member.age,
        active=member.active,
    )


def _task_response(task: HomeworkTask) -> HomeworkTaskResponse:
    return HomeworkTaskResponse(
        id=task.id,
        child_id=task.child_id,
        title=task.title,
        subject=task.subject,
        task_date=task.task_date,
        due_at=task.due_at,
        instructions=task.instructions,
        reference_answer=task.reference_answer,
        rubric=task.rubric,
        status=task.status,
        created_at=task.created_at,
        updated_at=task.updated_at,
    )


def _asset_response(asset: SubmissionAsset) -> HomeworkAssetResponse:
    return HomeworkAssetResponse(
        id=asset.id,
        media_type=asset.media_type,
        size_bytes=asset.size_bytes,
        sha256=asset.sha256,
        url=f"/api/v1/homework/assets/{asset.id}",
    )


def _review_response(review: HomeworkReview) -> HomeworkReviewResponse:
    return HomeworkReviewResponse(
        id=review.id,
        decision=review.decision,
        summary=review.summary,
        quality_level=review.quality_level,
        items=review.items_json,
        created_at=review.created_at,
    )


def _inspection_response(inspection: HomeworkInspection) -> HomeworkInspectionResponse:
    return HomeworkInspectionResponse(
        id=inspection.id,
        submission_id=inspection.submission_id,
        status=inspection.status,
        model_name=inspection.model_name,
        prompt_version=inspection.prompt_version,
        image_quality=inspection.image_quality,
        summary=inspection.summary,
        confidence=inspection.confidence,
        suggested_decision=inspection.suggested_decision,
        items=[
            HomeworkInspectionItemResponse.model_validate(item) for item in inspection.items_json
        ],
        error_code=inspection.error_code,
        created_at=inspection.created_at,
        completed_at=inspection.completed_at,
    )


async def _submission_response(
    repository: HomeworkRepository, household_id: str, submission: HomeworkSubmission
) -> HomeworkSubmissionResponse:
    assets = await repository.assets(household_id, submission.id)
    reviews = await repository.reviews(household_id, submission.id)
    return HomeworkSubmissionResponse(
        id=submission.id,
        task_id=submission.task_id,
        attempt_no=submission.attempt_no,
        status=submission.status,
        submitted_at=submission.submitted_at,
        assets=[_asset_response(item) for item in assets],
        reviews=[_review_response(item) for item in reviews],
    )


@router.get("/members", response_model=list[MemberResponse])
async def list_members(
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> list[MemberResponse]:
    current = await _current_parent(session, request, parent)
    members = await HomeworkRepository(session).members(current.user.household_id)
    return [_member_response(item) for item in members]


@router.post("/members", response_model=MemberResponse, status_code=201)
async def create_member(
    body: MemberCreate,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> MemberResponse:
    current = await _current_parent(session, request, parent)
    member = await HomeworkService(session).create_member(
        current, display_name=body.display_name, role=body.role, age=body.age
    )
    await session.commit()
    return _member_response(member)


@router.patch("/members/{member_id}", response_model=MemberResponse)
async def update_member(
    member_id: str,
    body: MemberUpdate,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> MemberResponse:
    current = await _current_parent(session, request, parent)
    member = await HomeworkService(session).update_member(
        current,
        member_id,
        display_name=body.display_name,
        age=body.age,
        active=body.active,
        set_age="age" in body.model_fields_set,
    )
    await session.commit()
    return _member_response(member)


@router.get("/tasks", response_model=list[HomeworkTaskResponse])
async def list_tasks(
    request: Request,
    child_id: str | None = Query(default=None, alias="childId"),
    task_date: date | None = Query(default=None, alias="date"),
    status: str | None = Query(default=None),
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> list[HomeworkTaskResponse]:
    current = await _current_parent(session, request, parent)
    if status is not None and status not in TASK_STATUSES:
        from home_agent.errors import DomainError

        raise DomainError("invalid_task_status", "Task status filter is invalid")
    tasks = await HomeworkRepository(session).tasks(
        current.user.household_id,
        child_id=child_id,
        task_date=task_date,
        status=status,
    )
    return [_task_response(item) for item in tasks]


@router.post("/tasks", response_model=HomeworkTaskResponse, status_code=201)
async def create_task(
    body: HomeworkTaskCreate,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> HomeworkTaskResponse:
    current = await _current_parent(session, request, parent)
    task = await HomeworkService(session).create_task(
        current,
        child_id=body.child_id,
        title=body.title,
        subject=body.subject,
        task_date=body.task_date,
        due_at=body.due_at,
        instructions=body.instructions,
        reference_answer=body.reference_answer,
        rubric=body.rubric,
    )
    await session.commit()
    return _task_response(task)


@router.get("/tasks/{task_id}", response_model=HomeworkTaskResponse)
async def get_task(
    task_id: str,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> HomeworkTaskResponse:
    current = await _current_parent(session, request, parent)
    task = await HomeworkService(session).require_task(current.user.household_id, task_id)
    return _task_response(task)


@router.patch("/tasks/{task_id}", response_model=HomeworkTaskResponse)
async def update_task(
    task_id: str,
    body: HomeworkTaskUpdate,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> HomeworkTaskResponse:
    current = await _current_parent(session, request, parent)
    mapping = {
        "task_date": "task_date",
        "due_at": "due_at",
        "reference_answer": "reference_answer",
    }
    changes: dict[str, Any] = {}
    for field in body.model_fields_set:
        key = mapping.get(field, field)
        changes[key] = getattr(body, field)
    task = await HomeworkService(session).update_task(current, task_id, changes)
    await session.commit()
    return _task_response(task)


@router.post("/tasks/{task_id}/start", response_model=HomeworkTaskResponse)
async def start_task(
    task_id: str,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> HomeworkTaskResponse:
    current = await _current_parent(session, request, parent)
    task = await HomeworkService(session).start_task(current, task_id)
    await session.commit()
    return _task_response(task)


@router.post("/tasks/{task_id}/cancel", response_model=HomeworkTaskResponse)
async def cancel_task(
    task_id: str,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> HomeworkTaskResponse:
    current = await _current_parent(session, request, parent)
    task = await HomeworkService(session).cancel_task(current, task_id)
    await session.commit()
    return _task_response(task)


@router.get("/tasks/{task_id}/submissions", response_model=list[HomeworkSubmissionResponse])
async def list_submissions(
    task_id: str,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> list[HomeworkSubmissionResponse]:
    current = await _current_parent(session, request, parent)
    service = HomeworkService(session)
    await service.require_task(current.user.household_id, task_id)
    submissions = await service.repository.submissions(current.user.household_id, task_id)
    return [
        await _submission_response(service.repository, current.user.household_id, item)
        for item in submissions
    ]


@router.post(
    "/tasks/{task_id}/submissions", response_model=HomeworkSubmissionResponse, status_code=201
)
async def create_submission(
    task_id: str,
    request: Request,
    files: list[UploadFile] = File(...),
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> HomeworkSubmissionResponse:
    current = await _current_parent(session, request, parent)
    repository = HomeworkRepository(session)
    asset_service = HomeworkAssetService(request.app.state.settings)
    used_bytes = await repository.used_asset_bytes(current.user.household_id)
    staged = await asset_service.stage(files, used_bytes=used_bytes)
    submission_id = new_id()
    finalized: list[dict[str, object]] = []
    try:
        finalized = await asset_service.finalize(
            staged,
            household_id=current.user.household_id,
            submission_id=submission_id,
        )
        records = [
            {key: item[key] for key in ("media_type", "local_path", "sha256", "size_bytes")}
            for item in finalized
        ]
        submission = await HomeworkService(session).create_submission(
            current, task_id, records, submission_id=submission_id
        )
        await session.commit()
        return await _submission_response(repository, current.user.household_id, submission)
    except Exception:
        await session.rollback()
        await asset_service.cleanup_finalized(finalized)
        raise
    finally:
        await asset_service.cleanup_staged(staged)


@router.get("/assets/{asset_id}")
async def get_asset(
    asset_id: str,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> FileResponse:
    current = await _current_parent(session, request, parent)
    asset = await HomeworkRepository(session).asset(current.user.household_id, asset_id)
    if asset is None:
        from home_agent.errors import DomainError

        raise DomainError("asset_not_found", "Homework image was not found", status_code=404)
    path = HomeworkAssetService(request.app.state.settings).resolve(asset.local_path)
    return FileResponse(path, media_type=asset.media_type, filename=path.name)


@router.post("/submissions/{submission_id}/review", response_model=HomeworkReviewResponse)
async def review_submission(
    submission_id: str,
    body: HomeworkReviewRequest,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> HomeworkReviewResponse:
    current = await _current_parent(session, request, parent)
    review = await HomeworkService(session).review_submission(
        current,
        submission_id,
        decision=body.decision,
        summary=body.summary,
        quality_level=body.quality_level,
        items=body.items,
    )
    await session.commit()
    return _review_response(review)


@router.get("/model-status", response_model=HomeworkModelStatusResponse)
async def homework_model_status(
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> HomeworkModelStatusResponse:
    await _current_parent(session, request, parent)
    inspector = OpenAICompatibleHomeworkInspector(request.app.state.settings)
    return HomeworkModelStatusResponse(
        enabled=request.app.state.settings.homework_model_enabled,
        configured=inspector.configured,
        base_url_host=inspector.base_url_host,
        model_name=request.app.state.settings.homework_model_name,
    )


@router.post(
    "/submissions/{submission_id}/inspect",
    response_model=HomeworkInspectionResponse,
    status_code=201,
)
async def inspect_submission(
    submission_id: str,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> HomeworkInspectionResponse:
    current = await _current_parent(session, request, parent)
    service = HomeworkInspectionService(session, request.app.state.settings)
    inspection, task, assets = await service.start(current, submission_id)
    await session.commit()

    try:
        result = await request.app.state.homework_inspector.inspect(
            task,
            assets,
            HomeworkAssetService(request.app.state.settings),
        )
    except InspectionProviderError as exc:
        await service.fail(current, task, inspection, exc.code)
    except Exception:
        await service.fail(current, task, inspection, "model_provider_error")
    else:
        await service.complete(current, task, inspection, result)
    await session.commit()
    return _inspection_response(inspection)


@router.get(
    "/submissions/{submission_id}/inspections",
    response_model=list[HomeworkInspectionResponse],
)
async def list_inspections(
    submission_id: str,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> list[HomeworkInspectionResponse]:
    current = await _current_parent(session, request, parent)
    service = HomeworkInspectionService(session, request.app.state.settings)
    await service.require_submission(current.user.household_id, submission_id)
    inspections = await service.repository.inspections(current.user.household_id, submission_id)
    return [_inspection_response(item) for item in inspections]


@router.get("/events", response_model=list[HomeworkEventResponse])
async def list_events(
    request: Request,
    task_id: str = Query(alias="taskId"),
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> list[HomeworkEventResponse]:
    current = await _current_parent(session, request, parent)
    service = HomeworkService(session)
    await service.require_task(current.user.household_id, task_id)
    events = await service.repository.events(current.user.household_id, task_id)
    return [
        HomeworkEventResponse(
            id=item.id,
            task_id=item.task_id,
            submission_id=item.submission_id,
            actor_type=item.actor_type,
            actor_id=item.actor_id,
            event_type=item.event_type,
            payload=item.payload_json,
            created_at=item.created_at,
        )
        for item in events
    ]
