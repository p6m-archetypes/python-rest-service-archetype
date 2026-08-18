from uuid import uuid4

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select

from ..domain.{{ entity_name }}s import {{ EntityName }}Entity
from ..persistence import get_session

# Sample scaffold CRUD routes for the {{ EntityName }} entity — the persistence round trip a
# black-box test can drive. The route is name-derived and versioned per the p6m platform
# standard (S2): /api/v1/{{ entity-name }}s. Rename alongside domain/{{ entity_name }}s.py when you add
# your real model.
router = APIRouter(prefix="/api/v1/{{ entity-name }}s")


class ItemRequest(BaseModel):
    display_name: str = Field(alias="displayName")


def _to_json(item: {{ EntityName }}Entity) -> dict:
    return {"id": item.id, "displayName": item.display_name}


@router.post("", status_code=201)
async def create_item(request: ItemRequest) -> dict:
    item = {{ EntityName }}Entity(id=str(uuid4()), display_name=request.display_name)
    async with get_session() as session:
        session.add(item)
        await session.commit()
    return _to_json(item)


@router.get("")
async def list_items() -> list[dict]:
    async with get_session() as session:
        result = await session.execute(select({{ EntityName }}Entity).order_by({{ EntityName }}Entity.created_at))
        return [_to_json(item) for item in result.scalars()]


@router.get("/{item_id}")
async def get_item(item_id: str) -> dict:
    async with get_session() as session:
        item = await session.get({{ EntityName }}Entity, item_id)
        if item is None:
            raise HTTPException(status_code=404, detail="{{ EntityName }} not found")
        return _to_json(item)


@router.put("/{item_id}")
async def update_item(item_id: str, request: ItemRequest) -> dict:
    async with get_session() as session:
        item = await session.get({{ EntityName }}Entity, item_id)
        if item is None:
            raise HTTPException(status_code=404, detail="{{ EntityName }} not found")
        item.display_name = request.display_name
        await session.commit()
        return _to_json(item)


@router.delete("/{item_id}", status_code=204)
async def delete_item(item_id: str) -> None:
    async with get_session() as session:
        item = await session.get({{ EntityName }}Entity, item_id)
        if item is None:
            raise HTTPException(status_code=404, detail="{{ EntityName }} not found")
        await session.delete(item)
        await session.commit()
