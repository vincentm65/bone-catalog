"""Run from catalog root: python3 tests/usage_sql_test.py"""
import sqlite3
import subprocess

sql = subprocess.check_output(
    ["luajit", "tests/usage_test.lua", "--sql"], text=True
)
original = """
SELECT coalesce(s.renamed, s.title, '(untitled)'), s.cwd,
       sum(u.input_tokens + u.output_tokens), count(*), s.id
FROM usage u JOIN sessions s ON s.id = u.session_id
WHERE u.at >= ?1 AND u.at < ?2
GROUP BY u.session_id ORDER BY sum(u.input_tokens + u.output_tokens) DESC LIMIT 6
"""
db = sqlite3.connect(":memory:")
db.executescript("""
CREATE TABLE sessions (id TEXT PRIMARY KEY, renamed TEXT, title TEXT, cwd TEXT);
CREATE TABLE usage (session_id TEXT, at INTEGER, input_tokens INTEGER, output_tokens INTEGER);
""")
for i in range(10):
    db.execute("INSERT INTO sessions VALUES (?, ?, ?, ?)",
               (str(i), "renamed" if i == 2 else None, None if i == 3 else "title", "/tmp"))
    for at in (99, 100, 101, 199, 200):
        db.execute("INSERT INTO usage VALUES (?, ?, ?, ?)", (str(i), at, i * 100, 1))
# Orphaned and sessionless calls must not displace real sessions in the top six.
for sid in ("", "deleted"):
    db.execute("INSERT INTO usage VALUES (?, 100, 999999, 0)", (sid,))
for span in ((100, 200), (0, 999), (200, 201), (0, 0)):
    assert db.execute(sql, span).fetchall() == db.execute(original, span).fetchall()
assert len(db.execute(sql, (100, 200)).fetchall()) == 6
conversation_sql = subprocess.check_output(
    ["luajit", "tests/usage_test.lua", "--conversation-sql"], text=True
)
db.executescript("""
ALTER TABLE usage ADD COLUMN cached_tokens INTEGER NOT NULL DEFAULT 0;
CREATE TABLE messages (session_id TEXT, role TEXT);
CREATE TABLE tool_calls (session_id TEXT, is_error INTEGER);
INSERT INTO messages VALUES ('1', 'user'), ('1', 'assistant'), ('1', 'user'), ('2', 'user');
INSERT INTO tool_calls VALUES ('1', 0), ('1', 1), ('1', NULL), ('2', 1), ('empty', 0);
INSERT INTO messages VALUES ('empty', 'user');
""")
row = db.execute(conversation_sql, ("1",)).fetchone()
assert row == (5, 500, 5, 0, 2, 1, 3, 1), row
# No recorded model calls must not hide user turns or tool calls.
assert db.execute(conversation_sql, ("empty",)).fetchone() == (0, None, None, None, 1, 0, 1, 0)
assert db.execute(conversation_sql, ("missing",)).fetchone() == (0, None, None, None, 0, 0, 0, None)
print("usage SQL equivalence tests passed")
