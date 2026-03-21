#!/usr/bin/env python3
"""
migrate.py
One-time migration script for NB Quiz.

Does two things:
  1. Uploads all quiz source files from quizzes/ directory to Firestore
  2. Migrates existing user progress from old quiz ID format (W7/Neuro/SAH)
     to new format (W7__Neuro__SAH)

Usage:
  python3 migrate.py

Requirements:
  pip install firebase-admin
  serviceAccountKey.json must be in the same folder as this script
"""

import os, re, sys, json, html

# ── Firebase admin setup ──────────────────────────────────────────────────────
try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError:
    print("[ERROR] firebase-admin not installed. Run: pip install firebase-admin")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
KEY_PATH   = os.path.join(SCRIPT_DIR, 'serviceAccountKey.json')

if not os.path.exists(KEY_PATH):
    print(f"[ERROR] serviceAccountKey.json not found at {KEY_PATH}")
    print("  Download it from Firebase Console → Project Settings → Service accounts")
    sys.exit(1)

cred = credentials.Certificate(KEY_PATH)
firebase_admin.initialize_app(cred)
db = firestore.client()

print("✅ Connected to Firestore\n")

# ── Helper: clean LaTeX/math from NotebookLM exports ─────────────────────────
def clean_math(text):
    if not text:
        return ''
    replacements = [
        (r'\$GCS\$',    'GCS'),   (r'\$CT\$',     'CT'),
        (r'\$MRI\$',    'MRI'),   (r'\$SpO_2\$',  'SpO2'),
        (r'\$PaO_2\$',  'PaO2'), (r'\$PaCO_2\$', 'PaCO2'),
        (r'\$FiO_2\$',  'FiO2'), (r'\$Na\^\+\$', 'Na+'),
        (r'\$K\^\+\$',  'K+'),   (r'\\\%',        '%'),
    ]
    for pat, rep in replacements:
        text = re.sub(pat, rep, text)
    text = re.sub(r'\\text\{([^}]+)\}', r'\1', text)
    text = re.sub(r'\$([^$]+)\$', r'\1', text)
    text = text.replace('\\u0027', "'")
    return text

# ── Extract questions from a pre-extracted JSON file ─────────────────────────
def extract_from_json(path):
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    quiz_arr = data.get('interactive_quiz', [])
    if not quiz_arr:
        return []
    questions = []
    for q in quiz_arr:
        options = {}
        rationales = {}
        for opt in q.get('options', []):
            letter = opt.get('letter')
            if not letter:
                continue
            options[letter] = opt.get('text', '')
            if opt.get('rationale'):
                rationales[letter] = opt.get('rationale', '')
        questions.append({
            'stem':       q.get('stem', ''),
            'options':    options,
            'rationales': rationales,
            'correct':    q.get('correct_answer', ''),
            'hint':       q.get('hint', ''),
            'part':       1,
        })
    return questions

# ── Extract questions from a NotebookLM shim.html file ───────────────────────
def extract_from_shim(path):
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        content = f.read()

    marker = 'data-app-data="'
    idx = content.find(marker)
    if idx == -1:
        return []

    raw_start = idx + len(marker)
    pos = raw_start
    while pos < len(content):
        if content[pos:pos+6] == '&quot;':
            pos += 6
        elif content[pos] == '"':
            break
        else:
            pos += 1

    raw_attr = content[raw_start:pos]
    decoded  = html.unescape(raw_attr)
    try:
        data = json.loads(decoded)
    except json.JSONDecodeError:
        return []

    quiz_arr = data.get('quiz', [])
    questions = []
    for q in quiz_arr:
        options = {}
        rationales = {}
        correct = None
        for j, opt in enumerate(q.get('answerOptions', [])):
            letter = chr(65 + j)
            options[letter] = clean_math(opt.get('text', ''))
            if opt.get('rationale'):
                rationales[letter] = clean_math(opt.get('rationale', ''))
            if opt.get('isCorrect'):
                correct = letter
        questions.append({
            'stem':       clean_math(q.get('question', '')),
            'options':    options,
            'rationales': rationales,
            'correct':    correct or '',
            'hint':       clean_math(q.get('hint', '')),
            'part':       1,
        })
    return questions

# ── Scan quizzes/ directory and upload to Firestore ───────────────────────────
def migrate_quizzes():
    quizzes_dir = os.path.join(SCRIPT_DIR, 'quizzes')
    if not os.path.exists(quizzes_dir):
        print(f"[WARN] quizzes/ directory not found at {quizzes_dir}")
        print("       Skipping quiz migration.\n")
        return []

    uploaded   = []
    skipped    = []
    failed     = []

    # Walk quizzes/WEEK/TOPIC/NAME.json (or .html)
    for week in sorted(os.listdir(quizzes_dir)):
        week_path = os.path.join(quizzes_dir, week)
        if not os.path.isdir(week_path) or week.startswith('.'):
            continue

        for topic in sorted(os.listdir(week_path)):
            topic_path = os.path.join(week_path, topic)
            if not os.path.isdir(topic_path) or topic.startswith('.'):
                continue

            # Collect unique base names (avoid processing both .json and .html
            # for the same quiz — prefer .json)
            seen = {}
            for fname in sorted(os.listdir(topic_path)):
                base, ext = os.path.splitext(fname)
                ext = ext.lower()
                if ext not in ('.json', '.html', '.htm'):
                    continue
                if base not in seen or ext == '.json':
                    seen[base] = os.path.join(topic_path, fname)

            for name, fpath in seen.items():
                quiz_id = f"{week}__{topic}__{name}"
                label   = f"{week}/{topic}/{name}"
                ext     = os.path.splitext(fpath)[1].lower()

                try:
                    if ext == '.json':
                        questions = extract_from_json(fpath)
                    else:
                        questions = extract_from_shim(fpath)

                    if not questions:
                        print(f"  [SKIP]  {label} — no questions extracted")
                        skipped.append(label)
                        continue

                    title = f"{week.upper()} · {topic} · {name}"

                    # Write metadata document
                    meta_ref = db.collection('quizzes').document(quiz_id)
                    meta_ref.set({
                        'week':          week.upper(),
                        'topic':         topic,
                        'name':          name,
                        'title':         title,
                        'questionCount': len(questions),
                        'updatedAt':     firestore.SERVER_TIMESTAMP,
                    })

                    # Write questions subcollection document
                    meta_ref.collection('data').document('questions').set({
                        'questions': questions
                    })

                    print(f"  [OK]    {label} — {len(questions)} questions → {quiz_id}")
                    uploaded.append((label, quiz_id))

                except Exception as e:
                    print(f"  [FAIL]  {label} — {e}")
                    failed.append(label)

    print(f"\n  Quiz migration: {len(uploaded)} uploaded, {len(skipped)} skipped, {len(failed)} failed\n")
    return uploaded

# ── Migrate user progress to new quiz ID format ───────────────────────────────
# Old format: W7/Neuro/SAH   (slashes — this was the quiz_id in Firestore)
# New format: W7__Neuro__SAH (double underscore)
def migrate_progress():
    print("── Migrating user progress ──────────────────────────────────────────")
    sessions_ref = db.collection('quizSessions')

    try:
        users = sessions_ref.stream()
    except Exception as e:
        print(f"  [ERROR] Could not read quizSessions: {e}\n")
        return

    total_migrated = 0
    total_users    = 0

    for user_doc in users:
        uid = user_doc.id
        user_migrated = 0

        # ── Migrate quiz progress ──
        quizzes_ref = sessions_ref.document(uid).collection('quizzes')
        try:
            quiz_docs = list(quizzes_ref.stream())
        except Exception as e:
            print(f"  [WARN] Could not read quizzes for {uid}: {e}")
            quiz_docs = []

        for quiz_doc in quiz_docs:
            old_id = quiz_doc.id

            # Only migrate if it uses the old slash format
            if '/' not in old_id:
                continue

            new_id = old_id.replace('/', '__')
            data   = quiz_doc.to_dict()

            try:
                # Write to new document
                quizzes_ref.document(new_id).set(data)
                # Delete old document
                quizzes_ref.document(old_id).delete()
                user_migrated += 1
                print(f"  [PROGRESS] {uid[:8]}… {old_id} → {new_id}")
            except Exception as e:
                print(f"  [WARN] Failed to migrate progress {old_id}: {e}")

        # ── Migrate notes ──
        notes_ref = sessions_ref.document(uid).collection('notes')
        try:
            note_docs = list(notes_ref.stream())
        except Exception as e:
            print(f"  [WARN] Could not read notes for {uid}: {e}")
            note_docs = []

        for note_doc in note_docs:
            old_id = note_doc.id
            if '/' not in old_id:
                continue
            new_id = old_id.replace('/', '__')
            data   = note_doc.to_dict()
            try:
                notes_ref.document(new_id).set(data)
                notes_ref.document(old_id).delete()
                print(f"  [NOTES]    {uid[:8]}… {old_id} → {new_id}")
            except Exception as e:
                print(f"  [WARN] Failed to migrate notes {old_id}: {e}")

        if user_migrated > 0:
            total_users    += 1
            total_migrated += user_migrated

    if total_migrated == 0:
        print("  No old-format progress records found (may already be migrated or none exist yet)")
    else:
        print(f"\n  Progress migration: {total_migrated} records across {total_users} users\n")

# ── Run ───────────────────────────────────────────────────────────────────────
if __name__ == '__main__':
    print("═" * 60)
    print("  NB Quiz — Firestore Migration")
    print("═" * 60 + "\n")

    print("── Uploading quizzes ────────────────────────────────────────────────")
    migrate_quizzes()

    print("── Migrating user progress ──────────────────────────────────────────")
    migrate_progress()

    print("\n" + "═" * 60)
    print("  Migration complete!")
    print("  Open your site and check that quizzes and progress appear correctly.")
    print("═" * 60)
