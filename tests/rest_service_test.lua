--- Acceptance suite for the Python REST service archetype (FastAPI + uv + pydantic-settings).
--- Renders the project, verifies the layout and template substitution, installs it, runs its own
--- unit suite, then boots the real service and proves the REST endpoint and the management sidecar
--- (health probes + Prometheus metrics) answer over the wire.
---
--- The default configuration weaves in no resources (persistence/cache/messaging = None): the
--- service is plain HTTP (FastAPI + uvicorn) with a management sidecar on a second port. The
--- persistence variants (PostgreSQL/MySQL) render the sample Item scaffold, boot against a real
--- database container, and prove REST CRUD calls round-trip into that database. This suite defines
--- the archetype's acceptance bar — its job is to fill the gaps and keep them filled.
---
--- The static tier reads the rendered tree with no toolchain; the build and live tiers require
--- `uv` (which provisions Python) and skip cleanly without it; the CRUD tiers additionally
--- require docker.
---
--- Run from the archetype repo root (uses ./prova.toml):   prova

local postgres = require("postgres")
local mysql    = require("mysql")

local SRC = "."

local ANSWERS = {
  author_name    = "Test Author",
  author_email   = "test@example.com",
  org_name       = "acme",
  solution_name  = "platform",
  prefix_name    = "Example",
  suffix_name    = "Service",
  image_registry = "ghcr.io/acme",
}

local function answers_with(extra)
  local out = {}
  for k, v in pairs(ANSWERS) do out[k] = v end
  for k, v in pairs(extra) do out[k] = v end
  return out
end

-- prefix Example / suffix Service => project dir `example-service`, package `example_service`,
-- console-script entrypoint `example-service` (project-name).
local PROJECT_DIR = "example-service"

local EXPECTED_FILES = {
  "pyproject.toml",
  ".python-version",
  ".env.example",
  "docker-compose.yml",
  "README.md",
  "src/example_service/__init__.py",
  "src/example_service/main.py",
  "src/example_service/router.py",
  "src/example_service/management.py",
  "src/example_service/settings.py",
  "tests/test_health.py",
  ".github/workflows/build.yaml",
  ".platform/docker/local/Dockerfile",
  ".platform/docker/prd/Dockerfile",
}

-- Files the persistence scaffold must produce (relative to the rendered project root):
-- the archetype's sample entity + CRUD routes, and the resource library's wiring.
local SCAFFOLD_FILES = {
  "src/example_service/domain/items.py",
  "src/example_service/api/items.py",
  "src/example_service/persistence/__init__.py",
  "src/example_service/persistence/models.py",
}

-- Render once for the whole suite. prova's in-process archetect renders a single tree per
-- fixture; every tier below shares it. No toolchain needed - pure in-process render.
local project = prova.fixture("python-rest:project", Scope.Suite, function(ctx)
  local tree = archetect.render{
    source = SRC,
    answers = ANSWERS,
    destination = ctx:tempdir(),
    defaults = true,
  }
  return tree:dir(PROJECT_DIR)
end)

-- Install once (shared by the build tier and the live-service fixture). Only ever reached from
-- uv-gated groups, so `uv` is guaranteed present here.
local installed = prova.fixture("python-rest:installed", Scope.Suite, function(ctx)
  local root = ctx:use(project)
  shell.run("uv sync --group dev", { cwd = root.path, timeout = "300s", check = true })
  return root
end)

-- Boot the rendered service on free ports (HOST/PORT/MANAGEMENT_PORT come from pydantic settings).
-- The management sidecar answering /health/liveness proves both uvicorn servers came up.
local service = prova.fixture("python-rest:service", Scope.Suite, function(ctx)
  local root = ctx:use(installed)

  local port, mgmt = net.free_port(), net.free_port()
  ctx:manage(shell.spawn("uv run " .. PROJECT_DIR, {
    cwd = root.path,
    env = {
      HOST            = "127.0.0.1",
      PORT            = port,
      MANAGEMENT_PORT = mgmt,
    },
  }))

  local mgmt_url = "http://127.0.0.1:" .. mgmt
  http.wait_for(mgmt_url .. "/health/liveness", { timeout = "60s" })
  return { service_url = "http://127.0.0.1:" .. port, mgmt_url = mgmt_url }
end)

-- Tier 1 - static: layout, template substitution, and generated k8s manifests. No toolchain.
prova.group("python-rest layout", function(g)
  g:test("scaffolds the expected project layout", function(t)
    local root = t:use(project).path
    t:expect_all(function()
      for _, f in ipairs(EXPECTED_FILES) do
        t:expect(fs.exists(root .. "/" .. f), f):is_true()
      end
    end)
  end)

  g:test("the hollow rendering stays hollow: no persistence scaffold", function(t)
    local root = t:use(project).path
    t:expect_all(function()
      for _, f in ipairs(SCAFFOLD_FILES) do
        t:expect(fs.exists(root .. "/" .. f), f .. " absent"):is_false()
      end
    end)
  end)

  g:test("wires prefix/suffix and ports through file contents", function(t)
    local root = t:use(project).path
    -- {{ PrefixName }}{{ SuffixName }} -> ExampleService in the app title; project-name in identity.
    t:expect(fs.read(root .. "/src/example_service/main.py"), "app title"):contains("ExampleService")
    t:expect(fs.read(root .. "/src/example_service/router.py"), "identity stub"):contains(PROJECT_DIR)
    -- service-port + derived management-port land in settings.
    local settings = fs.read(root .. "/src/example_service/settings.py")
    t:expect(settings, "service port"):contains("port: int = 8080")
    t:expect(settings, "management port"):contains("management_port: int = 8081")
  end)

  g:test("renders valid, non-empty kubernetes manifests", function(t)
    local root = t:use(project).path
    local manifests = fs.glob(root, ".platform/kubernetes/**/*.yaml")
    t:expect(#manifests > 0, "at least one k8s manifest"):is_true()
    t:expect_all(function()
      for _, m in ipairs(manifests) do
        -- Each manifest parses as YAML and declares a kind.
        local docs = yaml.parse_all(fs.read(m))
        t:expect(#docs > 0, m .. " has ≥1 document"):is_true()
      end
    end)
  end)

  g:test("leaves no unrendered template markers", function(t)
    -- The signature archetype check: no bare {{ }}, {% %}, or {# #} in contents or path segments
    -- (GitHub Actions ${{ … }} expressions are excluded by the matcher).
    t:expect(t:use(project)):is_fully_rendered()
  end)
end)

-- Tier 2 - build + unit: the generated project's own pytest suite passes.
prova.group("python-rest build + unit tests", { requires = { "uv" } }, function(g)
  g:test("the generated pytest suite passes", function(t)
    local root = t:use(installed).path
    local pytest = shell.run("uv run pytest -q", { cwd = root, timeout = "180s" })
    t:expect(pytest.code, "pytest exit code"):equals(0)
    t:expect(pytest.stdout .. pytest.stderr, "pytest reports a passing suite"):contains("passed")
  end)
end)

-- Tier 3 - live HTTP: the running service and its management sidecar answer real requests.
prova.group("python-rest HTTP endpoints", { requires = { "uv" } }, function(g)
  g:test("the service root returns the identity stub", function(t)
    local svc = t:use(service)
    local r = http.get(svc.service_url .. "/")
    t:expect(r.status):equals(200)
    local body = r:json()
    t:expect(body.service, "service name"):equals(PROJECT_DIR)
    t:expect(body.status, "service status"):equals("ok")
  end)

  g:test("the management sidecar reports readiness and liveness", function(t)
    local svc = t:use(service)

    local ready = http.get(svc.mgmt_url .. "/health/readiness")
    t:expect(ready.status, "readiness status code"):equals(200)
    t:expect(ready:json().status, "readiness body"):equals("ok")

    local live = http.get(svc.mgmt_url .. "/health/liveness")
    t:expect(live.status, "liveness status code"):equals(200)
    t:expect(live:json().status, "liveness body"):equals("ok")
  end)

  g:test("the management sidecar exposes Prometheus metrics", function(t)
    local svc = t:use(service)
    -- /metrics 307-redirects to /metrics/; hit the canonical path directly.
    local r = http.get(svc.mgmt_url .. "/metrics/")
    t:expect(r.status, "metrics status code"):equals(200)
    t:expect(r.body, "Prometheus exposition format"):contains("# HELP")
  end)
end)

-- Persistence variants: render with a real database backend, verify the scaffold, boot the
-- service against a database container, and prove REST CRUD calls round-trip into that database.
-- One entry per rendering variant. `db` is the container recipe namespace; the SQL strings carry
-- each backend's placeholder syntax (the scaffold uses snake_case identifiers, lowercase tables).
local VARIANTS = {
  {
    persistence = "PostgreSQL",
    db = postgres,
    db_port = 5432,
    count_by_name = [[SELECT count(*) FROM items WHERE display_name = $1]],
  },
  {
    persistence = "MySQL",
    db = mysql,
    db_port = 3306,
    count_by_name = "SELECT count(*) FROM items WHERE display_name = ?",
  },
}

for _, v in ipairs(VARIANTS) do
  local label = "python-rest[" .. v.persistence .. "]"

  -- a) render — one fixture per variant, shared by verify and the black-box tests.
  local variant_project = prova.fixture(label .. ":project", Scope.File, function(ctx)
    return archetect.render{
      source = SRC,
      answers = answers_with{ persistence = v.persistence },
      destination = ctx:tempdir(),
      defaults = true,
    }
  end)

  -- b) verify — layout, fully-rendered, and build checks against that rendering.
  archetect.verify(variant_project, {
    name = label,
    project_dir = PROJECT_DIR,
    expected_files = {
      "pyproject.toml",
      "src/example_service/main.py",
      "src/example_service/settings.py",
      SCAFFOLD_FILES[1], SCAFFOLD_FILES[2], SCAFFOLD_FILES[3], SCAFFOLD_FILES[4],
      ".github/workflows/build.yaml",
    },
    yaml_globs = { ".platform/kubernetes/**/*.yaml" },
    requires = { "uv" },
    build_steps = { "uv sync --group dev", "uv run pytest -q" },
  })

  -- c) black-box — provision the database, boot the installed service against it.
  local variant_service = prova.fixture(label .. ":service", Scope.File, function(ctx)
    local root = ctx:use(variant_project):dir(PROJECT_DIR)
    local db = v.db.container(ctx)

    shell.run("uv sync --group dev", { cwd = root.path, timeout = "300s", check = true })

    local port, mgmt = net.free_port(), net.free_port()
    ctx:manage(shell.spawn("uv run " .. PROJECT_DIR, {
      cwd = root.path,
      env = {
        -- pydantic-settings binds UPPER_SNAKE env vars onto the Settings fields.
        HOST            = "127.0.0.1",
        PORT            = port,
        MANAGEMENT_PORT = mgmt,
        DB_HOST         = db.host,
        DB_PORT         = db.port,
        DB_USERNAME     = "prova",
        DB_PASSWORD     = "prova",
        DB_DBNAME       = "prova",
      },
    }))

    -- The management sidecar proves the process is up; the service root only answers after the
    -- lifespan (init_db + ensure_schema) succeeded against the database.
    http.wait_for("http://127.0.0.1:" .. mgmt .. "/health/liveness", { timeout = "60s" })
    local api = http.client{ base_url = "http://127.0.0.1:" .. port }
    api:wait_for("/", { timeout = "60s" })
    return { api = api, db = db.client }
  end)

  prova.group(label .. " CRUD round-trip", { requires = { "docker", "uv" } }, function(g)
    g:test("created items land in " .. v.persistence, function(t)
      local svc = t:use(variant_service)

      -- Create through the public API...
      local created = svc.api:post("/api/items", { json = { displayName = "widget" } })
      t:expect(created.status):equals(201)
      local body = created:json()
      t:expect(body.displayName):equals("widget")
      t:expect(body.id, "created id"):is_truthy()

      -- ...and prove the row exists in the actual database, not just the API's memory.
      t:expect(svc.db:query_value(v.count_by_name, { "widget" }), "rows in DB"):equals(1)

      -- Read back through every door.
      t:expect(svc.api:get("/api/items/" .. body.id):json().displayName):equals("widget")
    end)

    g:test("updates and deletes round-trip into " .. v.persistence, function(t)
      local svc = t:use(variant_service)

      local body = svc.api:post("/api/items", { json = { displayName = "ephemeral" } }):json()

      local updated = svc.api:put("/api/items/" .. body.id, { json = { displayName = "renamed" } })
      t:expect(updated.status):equals(200)
      t:expect(svc.db:query_value(v.count_by_name, { "renamed" }), "renamed row in DB"):equals(1)
      t:expect(svc.db:query_value(v.count_by_name, { "ephemeral" }), "old name gone"):equals(0)

      t:expect(svc.api:delete("/api/items/" .. body.id).status):equals(204)
      t:expect(svc.api:get("/api/items/" .. body.id).status):equals(404)
      t:expect(svc.db:query_value(v.count_by_name, { "renamed" }), "row deleted from DB"):equals(0)
    end)
  end)
end
