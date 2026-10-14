import { useEffect, useState } from 'react';
import { io } from 'socket.io-client';
import './styles.css';

export default function App() {
  const [tasks, setTasks] = useState([]);
  const [title, setTitle] = useState('');
  const [error, setError] = useState('');
  const [live, setLive] = useState(false);

  useEffect(() => {
    fetch('/api/tasks').then((r) => r.json()).then(setTasks)
      .catch(() => setError('Could not load tasks. Please refresh.'));
    const socket = io();
    socket.on('connect', () => setLive(true));
    socket.on('disconnect', () => setLive(false));

    socket.on('task:created', (t) => setTasks((p) => (p.some((x) => x.id === t.id) ? p : [t, ...p])));
    socket.on('task:updated', (t) => setTasks((p) => p.map((x) => (x.id === t.id ? t : x))));
    return () => socket.close();
  }, []);

  async function submit(e) {
    e.preventDefault();
    setError('');
    const res = await fetch('/api/tasks', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title }),
    });
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      setError(body.error || 'Could not add the task.');
      return;
    }
    const task = await res.json();
    setTasks((p) => (p.some((x) => x.id === task.id) ? p : [task, ...p]));
    setTitle('');
  }

  return (
    <main>
      <header>
        <h1>Task dispatch</h1>
        <p className={live ? 'live on' : 'live'}>{live ? 'Live updates connected' : 'Reconnecting…'}</p>
      </header>
      <form onSubmit={submit}>
        <input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={100}
          placeholder="Describe a task, e.g. Resize invoice images" aria-label="Task title" />

        <button type="submit" disabled={!title.trim()}>Send to worker</button>
      </form>
      {error && <p className="error" role="alert">{error}</p>}
      {tasks.length === 0 ? (
        <p className="empty">No tasks yet. Add one and watch the Erlang worker finish it.</p>
      ) : (
        <ul>
          {tasks.map((t) => (
            <li key={t.id} className={t.status}>
              <div><strong>{t.title}</strong>{t.result && <span className="result">{t.result}</span>}</div>
              <span className="badge">{t.status === 'done' ? 'Done' : 'Processing'}</span>
            </li>
          ))}
        </ul>
      )}
    </main>
  );
}
