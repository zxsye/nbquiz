# PromptMX / Study OS — Firestore schema

Stable **document IDs** (slugs) identify entities; human-facing strings live in fields so labels can change without breaking clients.

All collections use the `pmx_` prefix to avoid colliding with NB Quiz collections (`quizzes`, `quizSessions`, etc.).

## Collections (catalog — admin-written, all signed-in users may read)

### `pmx_sections/{sectionId}`

| Field | Type | Description |
|--------|------|-------------|
| `name` | string | Display name (e.g. `Surgery`) |
| `icon` | string | Emoji or short icon token |
| `order` | number | Tab/list sort order |
| `isActive` | bool | If false, clients may hide |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |

**Document ID** = stable slug: `surgery`, `gp`, `medicine`.

---

### `pmx_promptTemplates/{templateId}`

| Field | Type | Description |
|--------|------|-------------|
| `name` | string | Display name |
| `description` | string | Admin / UI description |
| `content` | string | Full template text (`{{RAW_WEEK_DATA}}`, etc.) |
| `placeholders` | array&lt;string&gt; | Declared placeholders (documentation) |
| `stateKey` | string | Client map into local `promptTemplates` object: `curriculumExpansion`, `expansion`, `notes`, `mcqStyleGuide` |
| `version` | number | Bump when content meaningfully changes |
| `isActive` | bool | Inactive templates are ignored on load |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |

**Document IDs** (recommended): `curriculum_expansion`, `topic_expansion`, `study_notes`, `mcq_style_guide`.

---

### `pmx_workflowStepTypes/{stepId}`

Defines one pipeline step. **Document ID** must match the client’s `completedSteps` keys: `expand`, `notes`, `upload`, `questions`, `studied`.

| Field | Type | Description |
|--------|------|-------------|
| `name` | string | Step title |
| `icon` | string | Emoji |
| `subtitle` | string | Short subtitle |
| `instructions` | array&lt;string&gt; | HTML allowed in strings (e.g. `<strong>`) |
| `hasPrompt` | bool | |
| `promptTarget` | string | e.g. `Claude`, `NotebookLM Chat` |
| `hasResult` | bool | |
| `resultKey` | string | Topic field key (`expandedOutcomes`, `notes`) |
| `resultLabel` | string | UI label for paste area |
| `order` | number | Default ordering hint |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |

---

### `pmx_workflowDefinitions/{workflowId}`

| Field | Type | Description |
|--------|------|-------------|
| `name` | string | Display name |
| `description` | string | |
| `sectionId` | string | Optional default section slug this workflow targets |
| `stepIds` | array&lt;string&gt; | Ordered list of `pmx_workflowStepTypes` doc IDs |
| `isActive` | bool | |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |

**Default workflow ID**: `default_study`.

---

### `pmx_weekMasterData/{sectionId}__{weekId}` (optional)

Canonical week exports for import UIs or server-driven previews.

| Field | Type | Description |
|--------|------|-------------|
| `sectionId` | string | |
| `weekId` | string | e.g. `wk1` |
| `weekNumber` | number | |
| `name` | string | Week title |
| `rotation` | string | |
| `lectureMinutes` | number | |
| `rawDataFormat` | string | `json` \| `markdown` |
| `rawData` | string | Full export body |
| `isActive` | bool | |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |

---

## User data (owner-written)

### `pmx_userStudyOsState/{uid}`

Single document per Firebase Auth UID for Study OS local state mirror (avoids multi-doc fanout for typical sizes).

| Field | Type | Description |
|--------|------|-------------|
| `schemaVersion` | number | Currently `1` |
| `weeks` | array | Processed weeks + embedded `topics[]` (same shape as client) |
| `rawWeeks` | array | Raw imports (`rawData`, `source`, `metadata`, …) |
| `promptTemplates` | map | Optional per-user template overrides |
| `ui` | map | `activeTab`, `activeTopicId`, `activeRawWeekId`, `selectedSection`, `openStepId` |
| `updatedAt` | timestamp | Server timestamp on write |

**Normalized alternative** (for very large libraries): `pmx_userWorkflows/{id}` with a `topics` subcollection per week — same field shapes as embedded topics; rules become more complex. The client currently uses the single-document model.

## Security

See [`firestore.rules`](firestore.rules): catalog collections are read for any signed-in user, write for admins only; `pmx_userStudyOsState/{uid}` read/write for that uid only.

## Seeding

Use the **Cloud** tab in [`public/promptmx/surgery-study-os.html`](public/promptmx/surgery-study-os.html) (admins only) to write default sections, templates, step types, and `default_study` workflow definitions from the bundled defaults.
