# Master notes for agents working on NB Quiz

This file is the **running log of repo-wide context** that is easy to miss when you only open a few files. **Update this document when you make edits that future contributors (human or agent) should know about**—especially UI quirks, deployment steps, or cross-file contracts.

## How to use

- After completing a task, if you introduced or changed behavior that is not obvious from code alone, add a short dated bullet or paragraph here.
- Keep entries factual and scoped; link paths (`public/quiz.html`, `functions/index.js`) instead of pasting large blocks of code.
- Prefer updating this file over scattering one-off comments—unless an inline comment in the source is necessary for the next reader (both are fine together).

## Current notes

- **`public/quiz.html` — collapsed sidebar:** The narrow sidebar (`.sidebar.collapsed`) hides scrollbars on the vertical question list (`.collapsed-q-list`) while still allowing scroll via wheel/touch; the collapsed column uses `min-height: 0` / flex so the list scrolls inside the viewport without extra browser chrome. If you change sidebar layout or overflow, verify desktop and `<1000px` breakpoints and adjust this bullet.

- **`public/promptmx/surgery-study-os.html` — workflow tab surgical DOM updates:** `markDone` / `markUndone` avoid a full re-render by patching the DOM directly. A few gotchas discovered and fixed:
  - **Undo button detection:** The dynamically-created undo button in `updateStepCardVisuals` uses a JS event listener, not an inline `onclick` attribute, so `querySelector('button[onclick*="markUndone"]')` cannot find it. The fix is a dedicated `.step-undo-btn` class on both the statically-rendered undo button (in `buildStepCard`) and the dynamically-created one, and the selector uses that class instead.
  - **Step 2 "Notes from Step 1" box:** The upload step card (`id: 'upload'`) shows a read-only copy of the notes entered in Step 1. This box is always rendered in the DOM by `buildStepCard` with class `.upload-notes-box`, but hidden via `style="display:none"` when `topic.notes` is empty at render time. When `markDone` is called for the `notes` step, it finds the existing `.upload-notes-box`, updates its `.notes-result-content` text to the current `topic.notes` value, and clears `display:none`. Do **not** conditionally omit this element from the HTML or inject it dynamically — that caused duplicate boxes (static render + dynamic injection) and stale content after undo/redo cycles.

For Firebase hosting, callable functions, and local dev commands, see **`AGENTS.md`**.
