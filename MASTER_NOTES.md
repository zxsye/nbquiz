# Master notes for agents working on NB Quiz

This file is the **running log of repo-wide context** that is easy to miss when you only open a few files. **Update this document when you make edits that future contributors (human or agent) should know about**—especially UI quirks, deployment steps, or cross-file contracts.

## How to use

- After completing a task, if you introduced or changed behavior that is not obvious from code alone, add a short dated bullet or paragraph here.
- Keep entries factual and scoped; link paths (`public/quiz.html`, `functions/index.js`) instead of pasting large blocks of code.
- Prefer updating this file over scattering one-off comments—unless an inline comment in the source is necessary for the next reader (both are fine together).

## Current notes

- **`public/quiz.html` — collapsed sidebar:** The narrow sidebar (`.sidebar.collapsed`) hides scrollbars on the vertical question list (`.collapsed-q-list`) while still allowing scroll via wheel/touch; the collapsed column uses `min-height: 0` / flex so the list scrolls inside the viewport without extra browser chrome. If you change sidebar layout or overflow, verify desktop and `<1000px` breakpoints and adjust this bullet.

For Firebase hosting, callable functions, and local dev commands, see **`AGENTS.md`**.
