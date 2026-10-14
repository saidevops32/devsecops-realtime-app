const { Pool } = require('pg');

// PGHOST, PGUSER, PGPASSWORD, PGDATABASE are read by pg itself. Azure PostgreSQL needs TLS (PGSSL=true).
const pool = new Pool({
  max: 10,
  ssl: process.env.PGSSL === 'true' ? { rejectUnauthorized: false } : false,
});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function init() {
  for (let i = 0; i < 20; i++) {
    try {
      await pool.query(`CREATE TABLE IF NOT EXISTS tasks (
        id SERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        result TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT now())`);
      console.log('Database ready');
      return;
    } catch (err) {
      console.log('Database not ready, retrying in 3s...');
      await sleep(3000);
    }
  }
  throw new Error('Database unreachable');
}

// Parameterised queries only ($1, $2) to prevent SQL injection.
const listTasks = async () =>
  (await pool.query('SELECT * FROM tasks ORDER BY id DESC LIMIT 50')).rows;
const createTask = async (title) =>
  (await pool.query('INSERT INTO tasks (title) VALUES ($1) RETURNING *', [title])).rows[0];
const completeTask = async (id, result) =>
  (await pool.query("UPDATE tasks SET status='done', result=$2 WHERE id=$1 RETURNING *", [id, result])).rows[0];

module.exports = { init, listTasks, createTask, completeTask };
