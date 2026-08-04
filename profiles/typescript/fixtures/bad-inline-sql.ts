export function getUsers(db: { execute: (sql: string) => unknown }) {
    return db.execute("SELECT * FROM users");
}
