import sqlite3


def load_users(conn: sqlite3.Connection) -> list[tuple]:
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM users")
    return cursor.fetchall()
