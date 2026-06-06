const express = require('express');
const axios   = require('axios');
const fs      = require('fs');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3001;
const NOTIFICATION_SERVICE_URL = process.env.NOTIFICATION_SERVICE_URL || 'http://notification-service.notification-service.svc.cluster.local:3002';

// Reads a secret from the Key Vault CSI mount, falls back to env var
const getSecret = (name) => {
  try {
    return fs.readFileSync(`/mnt/secrets/${name}`, 'utf8').trim();
  } catch {
    return process.env[name.toUpperCase().replace(/-/g, '_')] || '';
  }
};

// In-memory store — replace with postgres using the mounted password in production
const orders = [];

app.get('/health',  (req, res) => res.json({ status: 'ok' }));
app.get('/version', (req, res) => res.json({ service: 'order-service', version: '1.0.0' }));

app.get('/secrets', (req, res) => {
  const dbPassword = getSecret('postgres-password');
  const apiKey     = getSecret('api-key');
  res.json({
    'postgres-password': dbPassword || 'not loaded',
    'api-key':           apiKey     || 'not loaded',
  });
});

app.get('/orders', (req, res) => res.json(orders));

app.get('/orders/:id', (req, res) => {
  const order = orders.find(o => o.id === req.params.id);
  if (!order) return res.status(404).json({ error: 'Order not found' });
  res.json(order);
});

app.post('/orders', async (req, res) => {
  const order = {
    id:        Date.now().toString(),
    ...req.body,
    status:    'created',
    createdAt: new Date().toISOString(),
  };
  orders.push(order);

  try {
    await axios.post(`${NOTIFICATION_SERVICE_URL}/notify`, {
      type:    'order_created',
      orderId: order.id,
      message: `Order ${order.id} created`,
    });
  } catch (err) {
    console.error('Notification failed:', err.message);
  }

  res.status(201).json(order);
});

app.patch('/orders/:id', (req, res) => {
  const idx = orders.findIndex(o => o.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Order not found' });
  orders[idx] = { ...orders[idx], ...req.body };
  res.json(orders[idx]);
});

app.listen(PORT, () => {
  const dbPass  = getSecret('postgres-password');
  const apiKey  = getSecret('api-key');
  console.log(`Order Service running on port ${PORT}`);
  console.log(`Secrets loaded — db: ${dbPass ? 'yes' : 'no'}, api-key: ${apiKey ? 'yes' : 'no'}`);
});
