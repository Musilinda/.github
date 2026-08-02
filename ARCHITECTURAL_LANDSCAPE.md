**Architectural Landscape (Workspace-Wide)**

This workspace is a multi-project platform, not one single deployable app.
It is organized as a product ecosystem with separate deployables plus a research pipeline.

1. Inference service: Python Flask API for audio-symbol matching
2. Main learning app: Full-stack React + Node/Express + Postgres
3. Blog CMS: Separate full-stack app with document ingestion and blob storage
4. Mobile shell: Capacitor iOS wrapper around deployed web app
5. Core R&D: Model training + notation generation pipelines
6. Marketing site: Static Vite/Tailwind site
7. Profile repo: Portfolio/meta docs tying all repos together

**System Context (ASCII)**

```text
                            +---------------------+
                            |      core/          |
                            | Offline R&D pipeline|
                            | model + score build |
                            +---------+-----------+
                                      |
                              exported artifacts
                            (onnx/pt/encoders/svg)
                                      v
+-------------------+        +--------+---------+        +-------------------+
|       api/        | <----> |  app_musilinda/  | <----> |   PostgreSQL DB   |
| Flask inference   |  HTTP  | React + Express  |  SQL   | (users/progress)  |
| token + analyze   |        | lesson platform  |        +-------------------+
+---------+---------+        +--------+---------+
          ^                           ^
          |                           |
          | API proxy                 | WebView target URL
          |                           |
+---------+---------+                 |
|   capacitor/      |-----------------+
| iOS native shell  |  wraps deployed app
| RevenueCat/AdMob  |
+-------------------+

+-------------------+        +-------------------+        +-------------------+
|      blog/        | <----> |   PostgreSQL DB   | <----> | Azure Blob/Azurite|
| React + TS server |  SQL   | blog/auth/analytics|       | uploaded images    |
| docx->content CMS |        +-------------------+        +-------------------+
+-------------------+

+-------------------+
|       web/        |
| static landing    |
| Vite + Tailwind   |
+-------------------+
```

**Per-Directory Architecture**

1. [api](api)

- Flask service with routes for health, token generation, and analysis.
- Loads local Whisper-based artifacts at startup and runs classification on base64 audio.
- Main app entry and endpoints: [api/app.py](api/app.py#L1)
- Service contract and runtime requirements: [api/README.md](api/README.md#L1)

1. [app_musilinda](app_musilinda)

- Full-stack product app:
- Frontend: React + Vite + TypeScript
- Backend: Express (TS), route-heavy API server
- DB: Drizzle + Postgres
- Explicit dependency on external audio API via AUDIO_API_BASE_URL:
- [app_musilinda/server/routes.ts](app_musilinda/server/routes.ts#L17)
- Inference flow is proxied through backend endpoints:
- token endpoint + analyze proxy in [app_musilinda/server/routes.ts](app_musilinda/server/routes.ts#L298)
- Package/runtime scripts: [app_musilinda/package.json](app_musilinda/package.json#L1)
- High-level architecture docs: [app_musilinda/README.md](app_musilinda/README.md#L1)

1. [blog](blog)

- Separate full-stack app with admin CMS and analytics.
- Backend handles auth, uploads, DOCX parsing, and blob proxying.
- Frontend is React/Vite; backend TS server with DB access.
- Route layer and upload pipeline: [blog/server/routes.ts](blog/server/routes.ts#L1)
- Architecture overview: [blog/README.md](blog/README.md#L1)
- Runtime/deps: [blog/package.json](blog/package.json#L1)

1. [capacitor](capacitor)

- Native iOS wrapper that points to deployed web app URL rather than bundling local app UI.
- Adds mobile-native monetization/subscription/device integrations.
- Architecture and plugin map: [capacitor/README.md](capacitor/README.md#L1)
- Wrapper scripts/deps: [capacitor/package.json](capacitor/package.json#L1)

1. [core](core)

- R&D and content-generation source of truth:
- Music notation generation pipeline in notebooks
- ML training/inference experimentation for syllable model
- Core summary: [core/README.md](core/README.md#L1)
- Notation pipeline details: [core/Music Scores/README.md](core/Music%20Scores/README.md#L1)
- ML pipeline details: [core/MusilindaSyllableInference/README.md](core/MusilindaSyllableInference/README.md#L1)

1. [web](web)

- Standalone static marketing/landing site.
- Vite build, static client files (no app server here).
- Site overview: [web/README.md](web/README.md#L1)
- Build scripts: [web/package.json](web/package.json#L1)
- Main HTML implementation: [web/client/index.html](web/client/index.html#L1)

1. [profile](profile)

- Documentation/meta repo connecting the project family and platform narrative.
- Portfolio-level map: [profile/README.md](profile/README.md#L1)

**Landscape Summary**

- Architecture style: federated multi-repo product suite in one workspace.
- Tightest runtime dependency: app_musilinda -> api for audio inference.
- Data domains are split:
- Learning app data in app_musilinda DB
- Blog/editorial data in blog DB + blob storage
- Core is upstream producer of ML artifacts and notation content, consumed downstream by product apps.
- Mobile is a shell strategy, not a separate duplicated product backend/frontend.
