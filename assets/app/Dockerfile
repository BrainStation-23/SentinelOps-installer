# Sentinel Ops frontend - production image.
#
# This file belongs in the Sentinel Ops application repository. The installer
# only supplies it when the repository does not carry one of its own.
#
# The application is a TanStack Start / Nitro app: it server-renders its HTML,
# so there is no index.html to serve statically. Stage 1 builds it with Nitro's
# node-server preset, stage 2 runs the resulting server bundle under Node.
#
# The repository's own vite.config.ts targets the netlify preset. That is left
# alone - NITRO_PRESET overrides it for this build only, so self-hosting here
# and deploying to Netlify from the same source stay compatible.

# ---------------------------------------------------------------------------
# Stage 1: build inside Docker
#
# Node 22 rather than 20: several of the application's dependencies declare
# "engines": { "node": ">=22.12.0" }, and building under 20 produces a stream of
# EBADENGINE warnings ahead of a failure that is hard to read back to its cause.
# ---------------------------------------------------------------------------
FROM node:22-alpine AS builder

# bun, copied from its official image rather than installed over the network,
# so the build stays reproducible and needs no extra tooling in this layer.
COPY --from=oven/bun:1-alpine /usr/local/bin/bun /usr/local/bin/bun

WORKDIR /app

# Whichever lockfiles the repository has. The trailing * on each makes the
# entry optional, so a project carrying only one of them still builds.
COPY package.json bun.lock* bun.lockb* pnpm-lock.yaml* yarn.lock* package-lock.json* ./

# Install from the lockfile the project actually maintains.
#
# Guessing wrong here is not a cosmetic problem: a repository whose real package
# manager is bun can carry a package-lock.json that has drifted weeks out of
# sync, and `npm ci` then fails with a wall of "Missing: X from lock file". The
# order below is most-specific first, and every branch installs from the lock
# rather than resolving afresh, so the build stays reproducible.
RUN set -eu; \
    if [ -f bun.lockb ] || [ -f bun.lock ]; then \
        echo "==> bun install --frozen-lockfile"; \
        bun install --frozen-lockfile; \
    elif [ -f pnpm-lock.yaml ]; then \
        echo "==> pnpm install --frozen-lockfile"; \
        corepack enable && corepack prepare pnpm@latest --activate && pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then \
        echo "==> yarn install --immutable"; \
        corepack enable && yarn install --immutable; \
    elif [ -f package-lock.json ]; then \
        echo "==> npm ci"; \
        npm ci; \
    else \
        echo "==> npm install (no lockfile found)"; \
        npm install; \
    fi

COPY . .

# Vite inlines VITE_* variables at build time, so they must be present here.
# Only the publishable (anon) key is passed in - it is public by design and is
# shipped to the browser. The service-role key must never appear in a build.
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_PUBLISHABLE_KEY
ARG VITE_SUPABASE_PROJECT_ID=local
ENV VITE_SUPABASE_URL=$VITE_SUPABASE_URL \
    VITE_SUPABASE_PUBLISHABLE_KEY=$VITE_SUPABASE_PUBLISHABLE_KEY \
    VITE_SUPABASE_PROJECT_ID=$VITE_SUPABASE_PROJECT_ID \
    NODE_ENV=production

# Build a self-hostable server bundle regardless of which platform the
# repository targets.
#
# The env vars alone are not enough: an explicit `nitro: { preset: "netlify" }`
# in vite.config.ts wins over NITRO_PRESET, and the build then emits a Netlify
# Functions bundle (.netlify/) with no standalone server to run. So the preset
# is rewritten in the copied source as well. This happens inside the build layer
# only - the repository's own vite.config.ts is untouched, so deploying the same
# source to Netlify still works.
ENV NITRO_PRESET=node-server \
    SERVER_PRESET=node-server

RUN ["node", "-e", "const fs=require('fs');let hit=false;for(const f of ['vite.config.ts','vite.config.js','vite.config.mts','vite.config.mjs']){if(!fs.existsSync(f))continue;const s=fs.readFileSync(f,'utf8');const n=s.replace(/(preset\\s*:\\s*)(\"[^\"]*\"|'[^']*')/g,(m,p1)=>p1+'\"node-server\"');if(n!==s){fs.writeFileSync(f,n);hit=true;console.log('==> pinned Nitro preset to node-server in '+f);}}if(!hit)console.log('==> no explicit Nitro preset found; relying on NITRO_PRESET');"]

RUN set -eu; \
    if [ -f bun.lockb ] || [ -f bun.lock ]; then \
        bun run build; \
    elif [ -f pnpm-lock.yaml ]; then \
        pnpm run build; \
    elif [ -f yarn.lock ]; then \
        yarn run build; \
    else \
        npm run build; \
    fi

# Nitro writes .output/; normalise it to /out so the runtime stage has one path.
RUN set -eu; \
    if [ -d .output ]; then \
        cp -r .output /out; \
    else \
        echo "" >&2; \
        echo "ERROR: the build produced no .output/ directory." >&2; \
        echo "" >&2; \
        echo "This image runs a Nitro server bundle, which the node-server preset" >&2; \
        echo "writes to .output/. What the build actually produced:" >&2; \
        ls -la >&2; \
        echo "" >&2; \
        exit 1; \
    fi

# The server entrypoint must exist, or the container would start, exit
# immediately, and look like a crash-looping application rather than a build
# that emitted the wrong shape.
RUN if [ ! -f /out/server/index.mjs ]; then \
        echo "" >&2; \
        echo "ERROR: .output/server/index.mjs is missing." >&2; \
        echo "The preset override did not take effect - the build targeted a" >&2; \
        echo "platform runtime (Netlify/Cloudflare/Vercel) instead of node-server." >&2; \
        echo "" >&2; \
        find /out -maxdepth 2 >&2; \
        echo "" >&2; \
        exit 1; \
    fi

# ---------------------------------------------------------------------------
# Stage 2: runtime
#
# Node only - no bun, no source, no node_modules. Nitro bundles every runtime
# dependency into .output/, so this image carries nothing else.
# ---------------------------------------------------------------------------
FROM node:22-alpine AS runtime

ARG APP_PORT=3000
ENV PORT=$APP_PORT \
    HOST=0.0.0.0 \
    NODE_ENV=production

WORKDIR /app
COPY --from=builder /out ./.output

# Drop privileges. The node image ships an unprivileged `node` user, and the
# server only ever reads from .output/.
USER node

EXPOSE 3000

# Any HTTP answer below 500 means the server is up and routing; a login
# redirect or a 404 on / is still a healthy server.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "require('http').get({host:'127.0.0.1',port:process.env.PORT,path:'/'},r=>process.exit(r.statusCode<500?0:1)).on('error',()=>process.exit(1))"

CMD ["node", ".output/server/index.mjs"]
