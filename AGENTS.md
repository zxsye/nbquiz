# AGENTS.md

## Cursor Cloud specific instructions

### Product overview
NB Quiz is a client-side web application (medical study quiz platform) hosted on **Firebase Hosting**, with **Gen2 callables** used from the admin UI: **topic tags** per quiz (`generateTopicTagsOpenAI` / `generateTopicTagsGemini`, models `gpt-4o-mini` / `gemini-2.5-flash`) and **week parent pills** (`regenerateWeekParentPillsOpenAI` / `regenerateWeekParentPillsGemini`) that cluster child topic pills across all quizzes in the same section+week. Parent docs live in Firestore `weekParentPills/{section}__{WEEK}` (week normalized uppercase, `/` → `_`). Topic generation **also** refreshes that week’s parent pill doc (best-effort; failures are logged). The admin picks the LLM provider per run from the Manage tab. The `public/` app has no build step and no root `package.json`; quiz UI dependencies (Firebase SDK, KaTeX, Google Fonts) load via CDN `<script>` tags. Cloud Functions live under [`functions/`](functions/) with their own `package.json`.

### Running the dev server
Serve the `public/` directory with any static HTTP server:
```
python3 -m http.server 8080 --directory public
```
Then open `http://localhost:8080/` in a browser.

### Authentication
The app requires Google sign-in via Firebase Auth. Without a valid Google account, you will only see the login screen. The Firebase project is `nbquiz-6faf9` with API keys hardcoded in the HTML files (standard for client-side Firebase apps; security is enforced via Firestore rules).

### Key pages
- `/` — Main quiz list (index.html) with section tabs (Surgery, GP, Medicine); each week may show **parent pill** links when `weekParentPills` exists
- `/quiz.html?id=<quiz_id>` — Single-quiz interface
- `/quiz.html?mode=parent&section=…&week=…&parentSlug=…` — Combined quiz over questions from member quizzes; progress/notes/flags read and write the **underlying** per-quiz `quizSessions` docs
- `/admin/` — Admin portal for uploading/managing quizzes (Manage → **Parent topics** per week, same provider dropdown as topic tags)

### Lint / Test / Build
- There is no linter or test suite configured in this repo.
- **API keys (secrets):** Each callable binds its own secret — set the ones you need, then redeploy:
  - `firebase functions:secrets:set OPENAI_API_KEY` — [OpenAI API keys](https://platform.openai.com/api-keys)
  - `firebase functions:secrets:set GEMINI_API_KEY` — [Google AI Studio](https://aistudio.google.com/apikey)  
  A full `firebase deploy --only functions` expects **both** secrets to exist; if you only use one provider, either create a placeholder value for the other secret or deploy a single function, e.g. `firebase deploy --only functions:generateTopicTagsOpenAI`. Cloud Functions require a **Blaze (pay-as-you-go)** plan.
- Deployment is handled via GitHub Actions on push to `main`: `firebase deploy --only hosting,functions` (uses `FIREBASE_SERVICE_ACCOUNT` for GCP auth).

### Caveats
- Google Auth popups require `localhost` origin (not `file://`).
- The app is non-functional without Firebase connectivity (Firestore for quiz data, Auth for login).
- **Gen2 callables** use Cloud Run under the hood. They are deployed with **`invoker: 'public'`** so browser CORS preflight (`OPTIONS`) succeeds; only signed-in admins can do anything useful because the handler checks `request.auth` and the `admins/{email}` document.
