# AGENTS.md

## Cursor Cloud specific instructions

### Product overview
NB Quiz is a static client-side web application (medical study quiz platform) hosted on Firebase Hosting. There is no build step, no `package.json`, and no server-side code. All dependencies (Firebase SDK, KaTeX, Google Fonts) are loaded via CDN `<script>` tags.

### Running the dev server
Serve the `public/` directory with any static HTTP server:
```
python3 -m http.server 8080 --directory public
```
Then open `http://localhost:8080/` in a browser.

### Authentication
The app requires Google sign-in via Firebase Auth. Without a valid Google account, you will only see the login screen. The Firebase project is `nbquiz-6faf9` with API keys hardcoded in the HTML files (standard for client-side Firebase apps; security is enforced via Firestore rules).

### Key pages
- `/` — Main quiz list (index.html) with section tabs (Surgery, GP, Medicine)
- `/quiz.html?id=<quiz_id>` — Quiz-taking interface
- `/admin/` — Admin portal for uploading/managing quizzes

### Lint / Test / Build
- There is no linter, test suite, or build step configured in this repo.
- Deployment is handled via GitHub Actions (`firebase deploy`) on push to `main`.

### Caveats
- Google Auth popups require `localhost` origin (not `file://`).
- The app is non-functional without Firebase connectivity (Firestore for quiz data, Auth for login).
