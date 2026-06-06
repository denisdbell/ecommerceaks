const express = require('express');

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3002;

const notifications = [];

app.get('/health',  (req, res) => res.json({ status: 'ok' }));
app.get('/version', (req, res) => res.json({ service: 'notification-service', version: '1.0.0' }));

app.post('/notify', (req, res) => {
  const notification = {
    id:         Date.now().toString(),
    ...req.body,
    receivedAt: new Date().toISOString(),
  };
  notifications.push(notification);
  console.log(`[NOTIFICATION] type=${notification.type} orderId=${notification.orderId} — ${notification.message}`);
  res.status(202).json({ received: true, id: notification.id });
});

app.get('/notifications', (req, res) => res.json(notifications));

app.listen(PORT, () => console.log(`Notification Service running on port ${PORT}`));
