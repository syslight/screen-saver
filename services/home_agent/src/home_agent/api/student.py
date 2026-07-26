from __future__ import annotations

from fastapi import APIRouter, Depends, File, Request, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from home_agent.api.dependencies import get_parent, get_session, get_student
from home_agent.api.schemas import (
    PairStudentDeviceRequest,
    PairStudentDeviceResponse,
    StudentDeviceResponse,
    StudentHomeworkReviewResponse,
    StudentHomeworkSubmissionResponse,
    StudentHomeworkTaskResponse,
    StudentMeResponse,
    StudentPairingCodeRequest,
    StudentPairingCodeResponse,
)
from home_agent.domain.models import HomeworkSubmission, HomeworkTask, new_id
from home_agent.repositories.auth import AuthenticatedParent
from home_agent.repositories.homework import HomeworkRepository
from home_agent.repositories.student import StudentPrincipal
from home_agent.services.auth import AuthService
from home_agent.services.homework import HomeworkService
from home_agent.services.homework_assets import HomeworkAssetService
from home_agent.services.student import StudentService

router = APIRouter(tags=["student"])


async def _current_parent(
    session: AsyncSession, request: Request, parent: AuthenticatedParent
) -> AuthenticatedParent:
    return await AuthService(session, request.app.state.settings).authenticate_parent_ids(
        parent.session.id, parent.user.id
    )


async def _current_student(
    session: AsyncSession, request: Request, student: StudentPrincipal
) -> StudentPrincipal:
    return await StudentService(session, request.app.state.settings).authenticate_ids(
        student.device.id, student.child.id
    )


def _task_response(task: HomeworkTask) -> StudentHomeworkTaskResponse:
    return StudentHomeworkTaskResponse(
        id=task.id,
        title=task.title,
        subject=task.subject,
        task_date=task.task_date,
        due_at=task.due_at,
        instructions=task.instructions,
        status=task.status,
        created_at=task.created_at,
        updated_at=task.updated_at,
    )


async def _submission_response(
    repository: HomeworkRepository,
    household_id: str,
    submission: HomeworkSubmission,
) -> StudentHomeworkSubmissionResponse:
    assets = await repository.assets(household_id, submission.id)
    reviews = await repository.reviews(household_id, submission.id)
    return StudentHomeworkSubmissionResponse(
        id=submission.id,
        task_id=submission.task_id,
        attempt_no=submission.attempt_no,
        status=submission.status,
        submitted_at=submission.submitted_at,
        asset_count=len(assets),
        reviews=[
            StudentHomeworkReviewResponse(
                decision=item.decision,
                summary=item.summary,
                quality_level=item.quality_level,
                created_at=item.created_at,
            )
            for item in reviews
        ],
    )


@router.post(
    "/api/v1/homework/student-pairing-codes",
    response_model=StudentPairingCodeResponse,
    status_code=201,
)
async def create_student_pairing_code(
    body: StudentPairingCodeRequest,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> StudentPairingCodeResponse:
    current = await _current_parent(session, request, parent)
    service = StudentService(session, request.app.state.settings)
    code, pairing = await service.create_pairing_code(current, body.child_id)
    child = await HomeworkRepository(session).member(current.user.household_id, body.child_id)
    assert child is not None
    await session.commit()
    return StudentPairingCodeResponse(
        code=code,
        child_id=child.id,
        child_name=child.display_name,
        expires_at=pairing.expires_at,
    )


@router.get("/api/v1/homework/student-devices", response_model=list[StudentDeviceResponse])
async def list_student_devices(
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> list[StudentDeviceResponse]:
    current = await _current_parent(session, request, parent)
    rows = await StudentService(session, request.app.state.settings).students.devices(
        current.user.household_id
    )
    return [
        StudentDeviceResponse(
            id=device.id,
            child_id=child.id,
            child_name=child.display_name,
            name=device.name,
            platform=device.platform,
            active=device.active,
            last_seen_at=device.last_seen_at,
            created_at=device.created_at,
        )
        for device, child in rows
    ]


@router.post(
    "/api/v1/homework/student-devices/{device_id}/revoke",
    response_model=StudentDeviceResponse,
)
async def revoke_student_device(
    device_id: str,
    request: Request,
    parent: AuthenticatedParent = Depends(get_parent),
    session: AsyncSession = Depends(get_session),
) -> StudentDeviceResponse:
    current = await _current_parent(session, request, parent)
    service = StudentService(session, request.app.state.settings)
    device = await service.revoke_device(current, device_id)
    child = await HomeworkRepository(session).member(current.user.household_id, device.child_id)
    assert child is not None
    await session.commit()
    return StudentDeviceResponse(
        id=device.id,
        child_id=child.id,
        child_name=child.display_name,
        name=device.name,
        platform=device.platform,
        active=device.active,
        last_seen_at=device.last_seen_at,
        created_at=device.created_at,
    )


@router.post("/api/v1/student/pair", response_model=PairStudentDeviceResponse, status_code=201)
async def pair_student_device(
    body: PairStudentDeviceRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
) -> PairStudentDeviceResponse:
    client = request.client.host if request.client else "unknown"
    request.app.state.student_pairing_limiter.check(client)
    device, device_key, child_name = await StudentService(session, request.app.state.settings).pair(
        body.code, body.name, body.platform
    )
    await session.commit()
    return PairStudentDeviceResponse(
        device_id=device.id,
        device_key=device_key,
        child_id=device.child_id,
        child_name=child_name,
    )


@router.get("/api/v1/student/me", response_model=StudentMeResponse)
async def get_student_me(
    request: Request,
    student: StudentPrincipal = Depends(get_student),
    session: AsyncSession = Depends(get_session),
) -> StudentMeResponse:
    current = await _current_student(session, request, student)
    await session.commit()
    return StudentMeResponse(
        device_id=current.device.id,
        device_name=current.device.name,
        child_id=current.child.id,
        child_name=current.child.display_name,
    )


@router.get("/api/v1/student/homework/tasks", response_model=list[StudentHomeworkTaskResponse])
async def list_student_tasks(
    request: Request,
    student: StudentPrincipal = Depends(get_student),
    session: AsyncSession = Depends(get_session),
) -> list[StudentHomeworkTaskResponse]:
    current = await _current_student(session, request, student)
    tasks = await HomeworkRepository(session).tasks(
        current.device.household_id, child_id=current.child.id
    )
    await session.commit()
    return [_task_response(item) for item in tasks]


@router.get(
    "/api/v1/student/homework/tasks/{task_id}",
    response_model=StudentHomeworkTaskResponse,
)
async def get_student_task(
    task_id: str,
    request: Request,
    student: StudentPrincipal = Depends(get_student),
    session: AsyncSession = Depends(get_session),
) -> StudentHomeworkTaskResponse:
    current = await _current_student(session, request, student)
    task = await HomeworkService(session).require_student_task(current, task_id)
    await session.commit()
    return _task_response(task)


@router.post(
    "/api/v1/student/homework/tasks/{task_id}/start",
    response_model=StudentHomeworkTaskResponse,
)
async def start_student_task(
    task_id: str,
    request: Request,
    student: StudentPrincipal = Depends(get_student),
    session: AsyncSession = Depends(get_session),
) -> StudentHomeworkTaskResponse:
    current = await _current_student(session, request, student)
    task = await HomeworkService(session).start_task_for_student(current, task_id)
    await session.commit()
    return _task_response(task)


@router.get(
    "/api/v1/student/homework/tasks/{task_id}/submissions",
    response_model=list[StudentHomeworkSubmissionResponse],
)
async def list_student_submissions(
    task_id: str,
    request: Request,
    student: StudentPrincipal = Depends(get_student),
    session: AsyncSession = Depends(get_session),
) -> list[StudentHomeworkSubmissionResponse]:
    current = await _current_student(session, request, student)
    service = HomeworkService(session)
    await service.require_student_task(current, task_id)
    submissions = await service.repository.submissions(current.device.household_id, task_id)
    result = [
        await _submission_response(service.repository, current.device.household_id, item)
        for item in submissions
    ]
    await session.commit()
    return result


@router.post(
    "/api/v1/student/homework/tasks/{task_id}/submissions",
    response_model=StudentHomeworkSubmissionResponse,
    status_code=201,
)
async def create_student_submission(
    task_id: str,
    request: Request,
    files: list[UploadFile] = File(...),
    student: StudentPrincipal = Depends(get_student),
    session: AsyncSession = Depends(get_session),
) -> StudentHomeworkSubmissionResponse:
    current = await _current_student(session, request, student)
    await HomeworkService(session).require_student_task(current, task_id)
    repository = HomeworkRepository(session)
    asset_service = HomeworkAssetService(request.app.state.settings)
    used_bytes = await repository.used_asset_bytes(current.device.household_id)
    staged = await asset_service.stage(files, used_bytes=used_bytes)
    submission_id = new_id()
    finalized: list[dict[str, object]] = []
    try:
        finalized = await asset_service.finalize(
            staged,
            household_id=current.device.household_id,
            submission_id=submission_id,
        )
        records = [
            {key: item[key] for key in ("media_type", "local_path", "sha256", "size_bytes")}
            for item in finalized
        ]
        submission = await HomeworkService(session).create_submission_for_student(
            current, task_id, records, submission_id=submission_id
        )
        await session.commit()
        return await _submission_response(repository, current.device.household_id, submission)
    except Exception:
        await session.rollback()
        await asset_service.cleanup_finalized(finalized)
        raise
    finally:
        await asset_service.cleanup_staged(staged)
