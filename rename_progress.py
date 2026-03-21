#!/usr/bin/env python3
"""
rename_progress.py
Renames and cleans up mismatched progress document IDs in quizSessions.
"""

import sys, os

# ── Rename these IDs to match the new quiz IDs ────────────────────────────────
RENAME_MAP = {
    'W1__Vascular__vascular1.1': 'W1__Vascular__v1',
}

# ── Delete these IDs — they can't be mapped (combined quiz or phantom docs) ───
DELETE_IDS = [
    'Neuro.And.Trauma',   # was a combined quiz — question indices no longer match
    'W7',                 # phantom leftover from the nested migration
]
# ─────────────────────────────────────────────────────────────────────────────

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError:
    print("[ERROR] Run: pip install firebase-admin")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
KEY_PATH   = os.path.join(SCRIPT_DIR, 'serviceAccountKey.json')
cred = credentials.Certificate(KEY_PATH)
firebase_admin.initialize_app(cred)
db = firestore.client()
print("✅ Connected to Firestore\n")


def list_mode():
    print("── Progress IDs in quizSessions ─────────────────────────────────────")
    progress_ids = set()
    for user_ref in db.collection('quizSessions').list_documents():
        for doc in user_ref.collection('quizzes').list_documents():
            progress_ids.add(doc.id)
    for pid in sorted(progress_ids):
        print(f"  {pid}")

    print("\n── Quiz IDs in quizzes/ ─────────────────────────────────────────────")
    quiz_ids = set()
    for doc in db.collection('quizzes').list_documents():
        quiz_ids.add(doc.id)
        print(f"  {doc.id}")

    print("\n── Mismatches (progress ID not found in quizzes/) ───────────────────")
    mismatches = progress_ids - quiz_ids
    if not mismatches:
        print("  None — all progress IDs match quiz IDs ✅")
    else:
        for m in sorted(mismatches):
            print(f"  ❌ {m}")


def rename_mode():
    total_renamed  = 0
    total_deleted  = 0

    for user_ref in db.collection('quizSessions').list_documents():
        uid = user_ref.id

        # ── Renames ──
        for old_id, new_id in RENAME_MAP.items():
            for col_name in ['quizzes', 'notes']:
                old_ref  = user_ref.collection(col_name).document(old_id)
                old_snap = old_ref.get()
                if not old_snap.exists or not old_snap.to_dict():
                    continue
                try:
                    user_ref.collection(col_name).document(new_id).set(old_snap.to_dict())
                    old_ref.delete()
                    print(f"  [RENAME] {uid[:8]}… {col_name}/{old_id} → {new_id}")
                    total_renamed += 1
                except Exception as e:
                    print(f"  [FAIL]   {uid[:8]}… {col_name}/{old_id}: {e}")

        # ── Deletions ──
        for del_id in DELETE_IDS:
            for col_name in ['quizzes', 'notes']:
                del_ref  = user_ref.collection(col_name).document(del_id)
                del_snap = del_ref.get()
                if not del_snap.exists:
                    continue
                try:
                    del_ref.delete()
                    print(f"  [DELETE] {uid[:8]}… {col_name}/{del_id}")
                    total_deleted += 1
                except Exception as e:
                    print(f"  [FAIL]   {uid[:8]}… {col_name}/{del_id}: {e}")

    print(f"\n  Done. {total_renamed} renamed, {total_deleted} deleted.")
    print("  Run with --list to verify everything looks clean.")


if __name__ == '__main__':
    if '--list' in sys.argv:
        list_mode()
    else:
        rename_mode()
