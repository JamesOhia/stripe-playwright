# DockerWork.md — Containerisation of the Playwright QA Suite

A complete record of every Docker change made to this project, explained for learning purposes.

---

## 1. Why Docker for a test suite?

A test suite needs the same environment everywhere — your laptop, your teammate's machine, GitHub Actions, and any future CI runner. Without Docker, "it works on my machine" is a real failure mode. Docker solves this by packaging the application code, its runtime (Node.js), the browser (Chromium), and all OS-level dependencies into a single, reproducible **image**.

| Without Docker | With Docker |
|---|---|
| Node.js version must match locally | Node version pinned in the image |
| Playwright browser install differs per OS | Chromium installed once, baked into image |
| CI setup duplicates local setup | CI just runs `docker run` |
| "Works on my machine" problems | One image runs identically everywhere |

---

## 2. What was wrong with the original Dockerfile

```dockerfile
# ORIGINAL — problems explained below
FROM mcr.microsoft.com/playwright:v1.30.0-focal   # ← Node 16, released 2023
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm install    # ← not reproducible
COPY . .
RUN mkdir -p allure-results allure-report test-results playwright-report
CMD ["npm", "test"]
```

### Problem 1 — Wrong Node.js version
`v1.30.0-focal` is built on Ubuntu 20.04 (Focal) and ships **Node 16**.  
`@playwright/test ^1.60.0` in `package.json` requires **Node 18+**.  
Result: the image fails to build or produces cryptic runtime errors.

### Problem 2 — Playwright browser version mismatch
The base image has Playwright browsers installed at version 1.30.  
The npm packages install a different version (1.60+).  
The browsers and the test runner version must match exactly. When they don't, Playwright throws:

```
Error: browserType.launch: Executable doesn't exist at /ms-playwright/chromium-xxx/chrome
```

### Problem 3 — `npm install` instead of `npm ci`
`npm install` can update `package-lock.json` if versions drift. Inside a container build you always want `npm ci` which:
- Respects `package-lock.json` exactly (reproducible)
- Fails if the lockfile is out of sync (catches issues early)
- Is faster because it skips the resolution step

### Problem 4 — No HEALTHCHECK
Docker has no way to tell if the container is "ready" or "broken". A HEALTHCHECK lets Docker (and orchestrators like Kubernetes or Docker Swarm) detect a sick container and restart it.

### Problem 5 — No layer caching optimisation
Copying all source files before installing dependencies means **any code change** invalidates the npm install layer and forces a full re-download of all packages. The fix is to copy `package.json` and `package-lock.json` first, run `npm ci`, then copy source.

---

## 3. The new Dockerfile — line by line

```dockerfile
FROM node:20-bookworm-slim
```
**Why `node:20-bookworm-slim`?**
- `node:20` — Node.js 20 LTS. Fully compatible with Playwright 1.60+.
- `bookworm` — Debian 12 (codename Bookworm). Stable, well-supported Linux base.
- `slim` — smaller than the full Debian image (~60 MB vs ~300 MB) because it strips documentation and extra locales. The `--with-deps` step adds back only what Chromium actually needs.

---

```dockerfile
WORKDIR /app
```
Sets the working directory inside the container. All subsequent `COPY`, `RUN`, and `CMD` instructions are relative to `/app`. This is a best practice — avoid building as root in `/`.

---

```dockerfile
COPY package.json package-lock.json ./
RUN npm ci
```
**Layer caching trick (critical for build speed):**  
Docker builds layer by layer, and each layer is cached by its inputs. By copying dependency files first and installing before the source code:
- If only your test code changes, Docker reuses the cached `npm ci` layer.
- A full package reinstall only happens when `package.json` or `package-lock.json` actually changes.

Without this ordering, every single code change would trigger a full `npm ci` + Playwright browser download — potentially 5+ minutes each time.

---

```dockerfile
RUN npx playwright install --with-deps chromium
```
**Why not rely on the base image browsers?**  
Using `node:20-bookworm-slim` as the base means no browsers are pre-installed. This command does two things:
1. **`--with-deps`** — automatically runs `apt-get install` for every OS-level library Chromium needs (libgtk, libnss, libasound, ~30 packages). You don't have to maintain this list manually.
2. **`install chromium`** — downloads the exact Chromium binary version that matches the `@playwright/test` version in `node_modules`. Version is always in sync.

Only Chromium is installed (not Firefox or WebKit) because that's all the tests use. Smaller image, faster builds.

---

```dockerfile
COPY . .
```
Source code goes here — after dependencies, so a code change doesn't bust the npm cache layer.

---

```dockerfile
RUN mkdir -p allure-results allure-report test-results playwright-report
```
Pre-creates output directories inside the image. Without this, volume mounts from CI (`-v host/allure-results:/app/allure-results`) can fail with "permission denied" because Docker creates the mount point as root.

---

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD node --version || exit 1
```
**How HEALTHCHECK works:**
- Docker runs `node --version` inside the running container every 30 seconds.
- If it fails 3 times in a row, the container is marked `unhealthy`.
- `--start-period=10s` — Docker waits 10 seconds after startup before the first check (gives Node time to initialise).
- For a test runner, this mainly signals whether the runtime is intact rather than a live service. It's valuable if the container is wrapped by a scheduler or run inside Kubernetes.

---

```dockerfile
CMD ["npm", "test"]
```
The default command when someone runs `docker run stripe-playwright`. Uses JSON array form (exec form) rather than shell form so signals (like `Ctrl+C` or `docker stop`) are passed directly to the Node process, not swallowed by a shell.

---

## 4. The .dockerignore file

`.dockerignore` works like `.gitignore` but for the Docker build context. When you run `docker build`, Docker sends your entire project directory to the Docker daemon. Large or sensitive directories bloat this transfer and slow builds.

Changes made:

| Entry | Reason |
|---|---|
| `auth/*.json` → `auth/` | Was only ignoring JSON files; now ignores the whole directory including subdirectories |
| Added `.auth/` | Playwright stores session state in `.auth/` (dot-prefix variant); excluded to prevent credentials leaking into the image |

Other important entries already present:
- `node_modules` — npm installs inside the container from the lockfile; local modules would conflict and are large
- `.env` / `.env.*` — never bake secrets into an image
- `allure-results`, `test-results` — generated outputs, not source

---

## 5. The GitHub Actions CI/CD pipeline

The workflow at `.github/workflows/playwright.yml` was previously entirely commented out. It is now active and Docker-based.

### Trigger events
```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:       # allows manual runs from the GitHub UI
```

### Job: `test`

**Step 1 — Docker Buildx setup**
```yaml
- uses: docker/setup-buildx-action@v3
```
Buildx is Docker's extended build system (BuildKit). It enables:
- **Layer caching to GitHub Actions cache** — layers are stored in GHA's cache API between runs
- Parallel build stages (if you add a multi-stage build later)
- Better build output and debugging

**Step 2 — Build image with GHA cache**
```yaml
- uses: docker/build-push-action@v6
  with:
    push: false      # don't push to a registry, just build locally
    load: true       # load the image into the local Docker daemon for use in the next step
    cache-from: type=gha
    cache-to: type=gha,mode=max
```
`cache-from: type=gha` — on the second run, Docker fetches already-built layers from GitHub's cache storage. Only changed layers are rebuilt. A layer that hasn't changed (e.g., the npm install layer) loads in seconds instead of 3–5 minutes.

**Step 3 — Run tests inside the container**
```yaml
- name: Run Playwright tests in Docker container
  env:
    STRIPE_SECRET_KEY: ${{ secrets.STRIPE_SECRET_KEY }}
    ...
  run: |
    docker run --rm \
      --user root \
      -e STRIPE_SECRET_KEY \
      -e STRIPE_PUBLISHABLE_KEY \
      ...
      -v "${{ github.workspace }}/allure-results:/app/allure-results" \
      -v "${{ github.workspace }}/test-results:/app/test-results" \
      stripe-playwright:${{ github.sha }}
```

Key decisions explained:

| Flag | Why |
|---|---|
| `--rm` | Automatically remove the container after it exits. Prevents accumulation of stopped containers on the runner. |
| `--user root` | The GitHub Actions workspace is owned by the runner user. Running as root inside the container ensures the volume-mounted directories are writable. Acceptable because CI runners are ephemeral and disposable. |
| `-e STRIPE_SECRET_KEY` (no `=value`) | Inherits the value from the step's `env:` block rather than inlining it. This way the secret value is never echoed in the shell command, which could appear in logs. |
| `-v host_path:/app/allure-results` | After the container exits, Allure results are on the host filesystem where the next steps (Allure CLI, upload-artifact) can access them. |
| `continue-on-error: true` | Even if tests fail, the workflow continues to generate and upload the Allure report. |

**Why are secrets safe in the `env:` block but not inline?**
GitHub Actions masks secret values in logs automatically. Using `-e VAR_NAME` (not `-e VAR_NAME=value`) forwards the already-masked host env var into Docker without creating a new shell interpolation that might log the value.

**Step 4 — Generate Allure report on the host**
The Allure CLI runs outside Docker on the runner host, using the files written to `allure-results/` via the volume mount. This is simpler than running it inside the container and then extracting the report.

**Step 5 — Allure history caching**
```yaml
- uses: actions/cache@v4
  with:
    path: allure-history
    key: allure-history-${{ github.run_id }}
    restore-keys: |
      allure-history-
```
Allure can show a trend graph (how many tests passed/failed over the last N runs). This requires persisting the `history/` folder between runs. GitHub Actions' cache does this — each run saves history, the next run restores it.

**Step 6 — Upload artifacts**
Two artifacts are uploaded after every run (even failing ones):
- `allure-report` — the full HTML report, downloadable from the Actions summary page
- `playwright-traces` — video, screenshots, and traces for failing tests

### Job: `deploy-pages`
Only runs on pushes to `main`. It takes the `allure-report` uploaded to GitHub Pages via `upload-pages-artifact` and makes it publicly accessible at your repo's GitHub Pages URL.

---

## 6. How the pieces fit together

```
Developer pushes code
        │
        ▼
GitHub Actions triggers
        │
        ▼
┌───────────────────────────────────────────────────────────────┐
│  Job: test                                                    │
│                                                               │
│  1. git checkout                                              │
│  2. Docker Buildx setup                                       │
│  3. docker build (uses GHA cache for layers)                  │
│         └── FROM node:20-bookworm-slim                        │
│         └── npm ci  (cached if package.json unchanged)        │
│         └── playwright install --with-deps chromium (cached)  │
│  4. docker run  (tests run inside container)                  │
│         └── Playwright auth setup (Stripe Dashboard login)    │
│         └── API tests                                         │
│         └── UI tests                                          │
│         └── E2E tests                                         │
│         └── allure-results/ written via volume mount          │
│  5. allure generate  (on host, from mounted results)          │
│  6. upload-artifact: allure-report                            │
│  7. upload-artifact: playwright-traces                        │
│  8. upload-pages-artifact (main only)                         │
└───────────────────────────────────────────────────────────────┘
        │  (main branch only)
        ▼
┌───────────────────────────────────────────────────────────────┐
│  Job: deploy-pages                                            │
│  Publishes allure-report/ to GitHub Pages                     │
└───────────────────────────────────────────────────────────────┘
```

---

## 7. Useful Docker commands for local development

```bash
# Build the image locally
docker build -t stripe-playwright:local .

# Run the full test suite (pass your .env values)
docker run --rm \
  --env-file .env \
  -v "$(pwd)/allure-results:/app/allure-results" \
  -v "$(pwd)/test-results:/app/test-results" \
  stripe-playwright:local

# Run only API tests
docker run --rm \
  --env-file .env \
  stripe-playwright:local \
  npm run test:api

# Open a shell inside the container to debug
docker run --rm -it --entrypoint bash stripe-playwright:local

# Check the image size
docker images stripe-playwright

# Remove old test images
docker rmi stripe-playwright:local

# Watch container health status
docker inspect --format='{{.State.Health.Status}}' <container_id>
```

---

## 8. Key concepts learned

| Concept | What it means |
|---|---|
| **Layer caching** | Docker caches each `RUN`/`COPY` instruction. Reordering instructions so rarely-changing steps come first makes rebuilds fast. |
| **Build context** | Everything in the project directory is sent to Docker when you build. `.dockerignore` trims it to only what's needed. |
| **Volume mount** | `-v host_path:container_path` makes a host directory visible inside a running container (and vice versa). Used here to extract test results. |
| **`npm ci` vs `npm install`** | `ci` is deterministic (lockfile wins), never writes back, and is faster — always prefer it inside Docker. |
| **Exec form CMD** | `CMD ["npm", "test"]` vs `CMD npm test`. Exec form sends OS signals directly to your process; shell form wraps in `/bin/sh -c` and can swallow signals. |
| **GHA cache** | `type=gha` tells BuildKit to use GitHub Actions' cache API as a storage backend for Docker layer cache. Layers that haven't changed are restored in seconds. |
| **HEALTHCHECK** | Docker periodically runs a command inside a running container. If it fails repeatedly, the container is marked `unhealthy` — useful for orchestrators and monitoring. |
| **`--with-deps`** | Playwright's installer flag that auto-resolves and installs all OS-level libraries required by the requested browser. No manual apt package lists needed. |

---

## 9. What to do next (optional improvements)

| Improvement | Why |
|---|---|
| Push image to GitHub Container Registry (GHCR) | Share the built image between jobs without rebuilding, and make it available for local pulls |
| Add a `lint` job before `test` | Catch type errors (`npm run typecheck`) early without waiting for a full test run |
| Pin the `node:20-bookworm-slim` digest | `node:20` tags are mutable (they point to the latest patch). Pinning to a SHA digest (`node:20@sha256:abc...`) makes builds fully reproducible |
| Multi-stage build | Use a `builder` stage for `npm ci` and a leaner `runtime` stage without build tools. Less relevant here since we need all devDependencies to run tests. |
| Matrix testing | Run tests in parallel across multiple browser configurations using a GitHub Actions matrix strategy |
