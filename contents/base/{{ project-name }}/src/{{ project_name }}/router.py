from fastapi import APIRouter
from fastapi.responses import JSONResponse

router = APIRouter()


@router.get("/")
async def ping() -> JSONResponse:
    return JSONResponse({"service": "{{ project-name }}", "status": "ok"})
