# ──────────────────────────────────────────────────────────────────────────────
#  Stripe Payment QA — Playwright test runner
#  Base: Node 20 LTS on Debian 12 (Bookworm Slim)
# ──────────────────────────────────────────────────────────────────────────────
FROM node:20-bookworm-slim

WORKDIR /app

# ── 1. Install Node dependencies first (layer is cached until package.json changes)
COPY package.json package-lock.json ./
RUN npm ci

# ── 2. Install Chromium browser + every OS-level system dependency it needs.
#       --with-deps runs apt-get automatically so we don't have to list packages.
RUN npx playwright install --with-deps chromium

# ── 3. Copy application source code (changes frequently; kept in its own layer)
COPY . .

# ── 4. Pre-create output directories so volume mounts work without permission errors
RUN mkdir -p allure-results allure-report test-results playwright-report

# ── 5. Healthcheck — verifies the Node runtime is alive inside the container.
#       Useful when the container is used as a service or behind a scheduler.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD node --version || exit 1

CMD ["npm", "test"]
