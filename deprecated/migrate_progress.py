#!/usr/bin/env python3
"""
migrate_progress.py
Migrates user progress from nested Firestore structure to flat document IDs.

Old path: quizSessions/{uid}/quizzes/W1/Vascular/vascular1.1
New path: quizSessions/{uid}/quizzes/W1__Vascular__vascular1.1

Same for notes.

Usage:
  python3 migrate_progress.py

Requirements:
  pip install firebase-admin
  serviceAccountKey.json must be in the same folder as this script
"""

import sys, os

try:
    import firebase_admin
    from firebase_admin import credentials, firestore
except ImportError:
    print("[ERROR] Run: pip install firebase-admin")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
KEY_PATH   = os.path.join(SCRIPT_DIR, 'serviceAccountKey.json')

if not os.path.exists(KEY_PATH):
    print(f"[ERROR] serviceAccountKey.json not found at {KEY_PATH}")
    sys.exit(1)

cred = credentials.Certificate(KEY_PATH)
firebase_admin.initialize_app(cred)
db = firestore.client()
print("✅ Connected to Firestore\n")


def migrate_collection(uid, col_name):
    """
    Traverses quizSessions/{uid}/{col_name}/{WEEK}/{TOPIC}/{NAME}
    and copies each document to quizSessions/{uid}/{col_name}/{WEEK}__{TOPIC}__{NAME}
    then deletes the old nested documents.
    Returns count of migrated records.
    """
    migrated = 0
    base_ref = db.collection('quizSessions').document(uid).collection(col_name)

    # Level 1: week (e.g. "W1", "W7")
    for week_ref in base_ref.list_documents():
        week = week_ref.id
        for topic_col in week_ref.collections():
            topic = topic_col.id
            for name_doc in topic_col.stream():
                # rest stays the same
                name     = name_doc.id
                data     = name_doc.to_dict()
                new_id   = f"{week}__{topic}__{name}"
                old_path = f"{week}/{topic}/{name}"

                if not data:
                    print(f"  [SKIP] {uid[:8]}… {col_name}/{old_path} — empty")
                    continue

                try:
                    base_ref.document(new_id).set(data)
                    name_doc.reference.delete()
                    print(f"  [OK]   {uid[:8]}… {col_name}/{old_path} → {new_id}")
                    migrated += 1
                except Exception as e:
                    print(f"  [FAIL] {uid[:8]}… {col_name}/{old_path}: {e}")

    return migrated


print("═" * 60)
print("  NB Quiz — Progress Migration")
print("═" * 60 + "\n")

user_docs = list(db.collection('quizSessions').list_documents())
print(f"Found {len(user_docs)} users\n")

total_quizzes = 0
total_notes   = 0

for user_doc in user_docs:
    uid = user_doc.id
    q = migrate_collection(uid, 'quizzes')
    n = migrate_collection(uid, 'notes')
    if q == 0 and n == 0:
        print(f"  {uid[:8]}… — no old-format records")
    total_quizzes += q
    total_notes   += n

print(f"\n{'═'*60}")
print(f"  Quiz progress migrated : {total_quizzes}")
print(f"  Notes migrated         : {total_notes}")
print(f"{'═'*60}")
