# {{ ProjectName }}

A FastAPI REST service.

## Development

```bash
# Install dependencies
uv sync --group dev

# Run the service
uv run uvicorn {{ project_name }}.main:app --reload --port {{ service_port }}

# Run tests
uv run pytest

# Run via entrypoint
uv run {{ project-name }}
```

## Configuration

Copy `.env.example` to `.env` and fill in values. Configuration is loaded from environment variables with prefix `APP_`.

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_HOST` | `0.0.0.0` | Bind host |
| `APP_PORT` | `{{ service_port }}` | Service port |
| `APP_MANAGEMENT_PORT` | `{{ management_port }}` | Health/readiness port |
| `APP_LOG_LEVEL` | `INFO` | Log level |
{% if persistence ~= 'None' %}| `DATABASE_URL` | — | SQLAlchemy async database URL |
{% endif %}{% if cache ~= 'None' %}| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection URL |
{% endif %}{% if messaging ~= 'None' %}| `BROKER_URL` | — | Messaging broker URL |
{% endif %}
