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

---

## 10. DevSecOps — Security scanning with Snyk and Docker Scout

**DevSecOps** means shifting security left: catching vulnerabilities during development and CI, not after deployment. The `security-scan` job in the workflow runs in **parallel** with the `test` job so it adds zero extra time to the pipeline.

---

### 10.1 The threat landscape for this project

This project has four surfaces that can carry vulnerabilities:

| Surface | Risk |
|---|---|
| **npm dependencies** | A transitive package (one you don't directly import) could have a known CVE — e.g. a prototype pollution bug in a deeply nested utility |
| **Source code (SAST)** | Developer mistakes: hard-coded tokens, insecure regex, injection-prone string building |
| **Docker base image** | `node:20-bookworm-slim` is built on Debian packages. Those packages get CVEs patched over time; a stale image carries unpatched OS vulnerabilities |
| **Dockerfile instructions** | Misconfigurations: running as root, exposing unnecessary ports, leaking build args as env vars |

Snyk and Docker Scout each cover different parts of this surface, which is why both are used.

---

### 10.2 Snyk — three scan types

Snyk is installed via `snyk/actions/setup@master`, which puts the latest Snyk CLI on the runner PATH.

#### A. Dependency scan (`snyk test`)

```bash
snyk test \
  --severity-threshold=medium \
  --json-file-output=snyk-deps.json \
  --sarif-file-output=snyk-deps.sarif
```

**What it checks:** every package in `node_modules`, including deeply nested transitive packages, against Snyk's vulnerability database (fed by NVD, GitHub Advisory, and Snyk's own research).

**Severity threshold explained:**
- `critical` — CVSS 9.0–10.0. Easily exploitable, often RCE or data exfiltration. Fix immediately.
- `high` — CVSS 7.0–8.9. Significant risk, commonly exploited in the wild. Fix in current sprint.
- `medium` — CVSS 4.0–6.9. Requires specific conditions. Fix in next sprint.
- `low` / `informational` — `--severity-threshold=medium` excludes these. They create noise without actionable risk for a test suite.

**On "confidence":** Snyk dependency findings are binary (the vulnerability either exists in the installed version or it doesn't). There is no ambiguity — the database maps exact package versions to CVE IDs.

**Output files:**
- `snyk-deps.json` — full machine-readable report. Each vulnerability entry contains: `id`, `title`, `severity`, `packageName`, `version`, `fixedIn`, `isUpgradable`, `isPatchable`, and a `remediation` block with exact upgrade commands.
- `snyk-deps.sarif` — same findings in SARIF format for GitHub Code Scanning.

#### B. SAST source code scan (`snyk code test`)

```bash
snyk code test \
  --severity-threshold=medium \
  --sarif-file-output=snyk-code.sarif
```

**What it checks:** JavaScript source files for security anti-patterns using Snyk's ML-based static analysis engine. Common findings:
- Hard-coded credentials or API keys
- SQL/command injection paths
- Prototype pollution
- Insecure use of `eval()` or `Function()`
- Path traversal in file operations

**On "confidence" for SAST:** Unlike dependency scans, SAST results can have false positives. Snyk Code's model is trained to minimise these, and `--severity-threshold=medium` already filters out low-confidence informational findings. In the SARIF output each finding has a `level` field (`error` = high/critical, `warning` = medium) which is a proxy for confidence.

**Requirement:** Snyk Code must be enabled for your Snyk organisation (Settings → Snyk Code → Enable). The step uses `continue-on-error: true` so the pipeline doesn't break if the feature is not yet enabled.

#### C. Docker container scan (`snyk container test`)

```bash
snyk container test \
  stripe-playwright:scan-${{ github.sha }} \
  --file=Dockerfile \
  --severity-threshold=medium \
  --json-file-output=snyk-container.json \
  --sarif-file-output=snyk-container.sarif
```

**What it checks:**
1. All OS packages installed in the image layers (Debian packages from `node:20-bookworm-slim` plus everything `--with-deps` installed)
2. The Dockerfile itself for misconfigurations (the `--file=Dockerfile` flag)

**What `--file=Dockerfile` adds:** Snyk analyses the Dockerfile instructions for issues like:
- `USER root` at the end (running production services as root)
- `ADD` used where `COPY` is safer
- Secrets passed via `ARG` or `ENV`
- Missing `--no-cache` on `apt-get install`

Output structure in `snyk-container.json`:
```json
{
  "vulnerabilities": [
    {
      "id": "SNYK-DEBIAN12-LIBSSL3-XXXXX",
      "title": "...",
      "severity": "high",
      "packageName": "libssl3",
      "version": "3.0.x",
      "fixedIn": ["3.0.y"],
      "nearestFixedInVersion": "3.0.y",
      "dockerfileInstruction": "RUN npx playwright install --with-deps chromium"
    }
  ],
  "docker": {
    "baseImage": "node:20-bookworm-slim",
    "baseImageRemediation": {
      "advice": [
        { "message": "Base Image  node:20-alpine\nVulnerabilities  0C 0H 0M" }
      ]
    }
  }
}
```
The `baseImageRemediation` section is particularly valuable — it tells you which alternative base image would eliminate the most vulnerabilities.

---

### 10.3 Docker Scout — independent CVE second opinion

Docker Scout is Docker's native image vulnerability scanner. It uses a different vulnerability database (Docker's own CVE feed + NVD) which means it can surface findings Snyk misses, and vice versa. Having both provides defence-in-depth for the image scanning layer.

```yaml
- uses: docker/scout-action@v1
  with:
    command: cves
    image: local://stripe-playwright:scan-${{ github.sha }}
    only-severities: critical,high,medium
    sarif-file: docker-scout-cves.sarif
    summary: true
```

**`local://` prefix:** tells Scout the image is already in the local Docker daemon (built in the previous step). Without this prefix, Scout tries to pull the image from Docker Hub.

**`only-severities: critical,high,medium`:** maps directly to CVSS score bands. Scout shows a table in the workflow log summary so you can see the count at a glance without downloading any files.

**Why two Scout steps (SARIF then JSON)?** Docker Scout cannot output SARIF and JSON simultaneously in a single action invocation. The `sarif-file` parameter implies SARIF format; the `format: json` parameter writes JSON to `output`. Running the action twice on the same cached image is fast.

**Docker Scout JSON structure** (`docker-scout-cves.json`):
```json
{
  "vulnerabilities": [
    {
      "cve_id": "CVE-2024-XXXXX",
      "severity": "high",
      "package": { "name": "libssl3", "version": "3.0.x" },
      "fix": { "versions": ["3.0.y"] },
      "description": "...",
      "cvss_score": 8.1
    }
  ]
}
```

---

### 10.4 How SARIF flows to GitHub Code Scanning

SARIF (Static Analysis Results Interchange Format) is a JSON schema standardised by OASIS. GitHub natively understands SARIF and shows the results in three places:

1. **Security tab → Code scanning alerts** — every finding gets its own alert with file+line annotation, severity badge, and a link to the CWE.
2. **Pull Request "Checks" tab** — new findings introduced by a PR are flagged inline in the diff view, so reviewers see them without leaving the PR.
3. **Security Overview** — organization-level view of all repos' alert counts.

The `category` field on `upload-sarif` groups alerts by tool:
```yaml
category: snyk-dependencies   # npm CVEs
category: snyk-code            # SAST findings
category: snyk-container       # image/OS CVEs
category: docker-scout         # Scout CVEs (second opinion)
```

`hashFiles('file.sarif') != ''` in the `if:` condition prevents the upload step from failing when a scan step errored before writing its output file.

---

### 10.5 How to use the JSON reports with an AI tool for remediation

When the `security-scan` job finishes:

1. Go to the GitHub Actions run page.
2. Scroll to "Artifacts" at the bottom → download **security-reports.zip**.
3. Unzip it. You'll find:
   - `snyk-deps.json` — npm dependency CVEs
   - `snyk-container.json` — Docker image OS CVEs
   - `docker-scout-cves.json` — Docker Scout CVEs
   - `snyk-code.sarif`, `snyk-deps.sarif`, `snyk-container.sarif`, `docker-scout-cves.sarif` — GitHub Code Scanning uploads

4. Open Claude Code (or any AI tool) and paste the JSON content with a prompt like:

```
Here are my Snyk dependency scan results (snyk-deps.json):

<paste JSON here>

Please:
1. List findings by severity (critical first).
2. For each finding, give me the exact npm command to fix it.
3. Flag any that have no fix available.
```

**Why JSON beats HTML for AI consumption:**
- HTML is for human reading — it contains layout, icons, and navigation.
- JSON is structured data — the AI can map `packageName` + `version` → `fixedIn` without parsing HTML.
- The AI can generate `npm update <package>@<fixedVersion>` commands, Dockerfile `FROM` changes, or `package.json` pinning — directly from the structured fields.

---

### 10.6 New secrets required

Add these in: GitHub repo → Settings → Secrets and variables → Actions → New repository secret.

| Secret name | How to get it |
|---|---|
| `SNYK_TOKEN` | Log into [app.snyk.io](https://app.snyk.io) → Account Settings → Auth Token |
| `DOCKERHUB_USERNAME` | Your Docker Hub username (not email) |
| `DOCKERHUB_TOKEN` | Docker Hub → Account Settings → Personal Access Tokens → Create token with **Read-only** scope |

> **Security note:** use a Read-only Docker Hub token — the `security-scan` job only needs to pull Scout's CVE database, never push. Least-privilege principle.

---

### 10.7 Updated pipeline flow with security scanning

```
Developer pushes code
        │
        ├──────────────────────────────────────────┐
        ▼                                          ▼
┌───────────────────────┐              ┌───────────────────────────────────────────────┐
│  Job: test            │              │  Job: security-scan (runs in parallel)        │
│                       │              │                                               │
│  1. docker build      │              │  1. npm ci  (Snyk dep scan needs node_modules)│
│  2. docker run tests  │              │  2. snyk test → snyk-deps.json + .sarif       │
│  3. allure generate   │              │  3. snyk code test → snyk-code.sarif          │
│  4. upload artifacts  │              │  4. docker build (cached layers)              │
│                       │              │  5. snyk container test → .json + .sarif      │
└───────────────────────┘              │  6. docker login (Docker Hub)                 │
        │                              │  7. docker scout → .sarif (GitHub Scanning)   │
        │ (main only)                  │  8. docker scout → .json  (AI artifact)       │
        ▼                              │  9. upload SARIF → GitHub Code Scanning       │
┌───────────────────────┐              │ 10. upload artifact: security-reports.zip     │
│  Job: deploy-pages    │              └───────────────────────────────────────────────┘
│  GitHub Pages         │
└───────────────────────┘
```

---

### 10.8 Additional security scanning tools recommended

The Snyk + Docker Scout combination covers dependencies and images well, but two important surfaces are still uncovered:

#### 1. Secret / credential leak detection — Gitleaks (STRONGLY RECOMMENDED for this project)

**Why critical here:** this project handles Stripe API keys, dashboard credentials, and webhook secrets. A developer accidentally committing a `.env` file or an API key in a test fixture is a real risk.

**What it does:** scans the entire git history and current files for patterns that look like secrets (API keys, private keys, tokens, connection strings). It uses a library of 150+ secret patterns.

**How to add it:**
```yaml
- name: Gitleaks — secret detection
  uses: gitleaks/gitleaks-action@v2
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}  # free for public repos
```

Gitleaks will fail the job (exit code 1) if it finds a committed secret — which is the correct behaviour. You want the build to break rather than let a leaked key reach `main`.

#### 2. npm audit (built-in, zero config, no token needed) 

```yaml
- name: npm audit (critical and high only)
  run: npm audit --audit-level=high
  continue-on-error: true
```

`npm audit` uses the npm Advisory Database (slightly different from Snyk's). It requires no tokens, no accounts. Running both Snyk and npm audit gives the widest CVE coverage. Use `--audit-level=high` to only exit non-zero for high/critical findings.

#### 3. Trivy (optional alternative / complement to Docker Scout)

Trivy by Aqua Security is a free, no-login-required image scanner with excellent CVE coverage. It can scan images, filesystems, git repos, and IaC. If Docker Hub login is unavailable (e.g. organisation policy), Trivy is the drop-in replacement for Docker Scout:

```yaml
- name: Trivy — container vulnerability scan
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: stripe-playwright:scan-${{ github.sha }}
    format: sarif
    output: trivy-results.sarif
    severity: CRITICAL,HIGH,MEDIUM
    exit-code: 0   # informational; don't fail the job
```

#### Summary of recommended stack

| Tool | Surface | Token required? | When to add |
|---|---|---|---|
| **Snyk** (already added) | npm deps, SAST, container | Yes (free tier) | Done |
| **Docker Scout** (already added) | Container image CVEs | Docker Hub PAT | Done |
| **Gitleaks** | Committed secrets/keys | Free for public repos | Add now — high value for Stripe keys |
| **npm audit** | npm deps (second DB) | No | Add now — zero friction |
| **Trivy** | Container image CVEs | No | Add if Docker Hub auth is unavailable |

---

### 10.9 DevSecOps concepts glossary

| Term | What it means |
|---|---|
| **CVE** | Common Vulnerabilities and Exposures — a unique ID (e.g. CVE-2024-12345) assigned to a specific vulnerability |
| **CVSS** | Common Vulnerability Scoring System — a 0–10 number rating how severe a CVE is |
| **SAST** | Static Application Security Testing — analysing source code without running it |
| **DAST** | Dynamic Application Security Testing — analysing a running app (not implemented here) |
| **SARIF** | Static Analysis Results Interchange Format — a JSON schema that GitHub uses to render inline code annotations in PRs and the Security tab |
| **Shift left** | Moving security checks earlier in the development lifecycle (into CI/PR, not just pre-release audits) |
| **Least privilege** | Every token/credential should have the minimum permissions it needs — hence the Read-only Docker Hub PAT |
| **Defence in depth** | Using multiple tools with overlapping coverage (Snyk + Docker Scout) so no single tool's blind spot becomes a gap |
| **False positive** | A reported vulnerability that is not actually exploitable in your context |
| **Transitive dependency** | A package you didn't directly install, but one of your dependencies installed — most CVEs come from here |
