const amqp = require('amqplib');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let channel;

function url() {
  const u = encodeURIComponent(process.env.RABBITMQ_USER || 'guest');
  const p = encodeURIComponent(process.env.RABBITMQ_PASS || 'guest');
  return `amqp://${u}:${p}@${process.env.RABBITMQ_HOST || 'localhost'}:${process.env.RABBITMQ_PORT || 5672}`;
}

async function start(onResult) {
  let conn;
  for (let i = 0; i < 20; i++) {
    try { conn = await amqp.connect(url()); break; }
    catch (err) { console.log('RabbitMQ not ready, retrying in 3s...'); await sleep(3000); }
  }
  if (!conn) throw new Error('RabbitMQ unreachable');

  conn.on('error', (e) => console.error('RabbitMQ error:', e.message));
  conn.on('close', () => { console.error('RabbitMQ closed'); process.exit(1); }); // fail fast, Azure restarts us

  channel = await conn.createChannel();
  await channel.assertQueue('tasks', { durable: true });
  await channel.assertQueue('results', { durable: true });
  channel.consume('results', async (msg) => {
    if (!msg) return;
    try { await onResult(JSON.parse(msg.content.toString())); channel.ack(msg); }
    catch (err) { console.error('Bad result message:', err.message); channel.nack(msg, false, false); }
  });
  console.log('RabbitMQ ready');
}

function publishTask(task) {
  channel.sendToQueue('tasks', Buffer.from(JSON.stringify({ id: task.id, title: task.title })),
    { persistent: true, contentType: 'application/json' });
}

module.exports = { start, publishTask };
