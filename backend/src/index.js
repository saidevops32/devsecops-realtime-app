const http = require('http');
const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const { Server } = require('socket.io');
const db = require('./db');
const mq = require('./mq');
const { validateTitle } = require('./validate');

const app = express();
app.set('trust proxy', 2);                 // Application Gateway + nginx in front
app.use(helmet());
app.use(express.json({ limit: '10kb' }));
app.use('/api', rateLimit({ windowMs: 60_000, limit: 100 }));

const server = http.createServer(app);
const io = new Server(server);

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.get('/api/tasks', async (_req, res, next) => {
  try { res.json(await db.listTasks()); } catch (e) { next(e); }
});

app.post('/api/tasks', async (req, res, next) => {
  try {
    const title = validateTitle(req.body && req.body.title);
    if (!title) return res.status(400).json({ error: 'Title must be 1-100 characters.' });
    const task = await db.createTask(title);
    mq.publishTask(task);
    io.emit('task:created', task);
    res.status(201).json(task);
  } catch (e) { next(e); }
});

app.use((err, _req, res, _next) => {       // never leak internals
  console.error(err);
  res.status(500).json({ error: 'Something went wrong.' });
});

async function main() {
  await db.init();
  await mq.start(async (result) => {
    const task = await db.completeTask(result.id, result.result);
    if (task) io.emit('task:updated', task);
  });
  server.listen(process.env.PORT || 3000, () => console.log('Backend listening'));
}
main().catch((e) => { console.error(e); process.exit(1); });
