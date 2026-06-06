const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
const PORT = process.env.PORT || 3000;

const ORDER_SERVICE_URL      = process.env.ORDER_SERVICE_URL      || 'http://order-service.order-service.svc.cluster.local:3001';
const NOTIFICATION_SERVICE_URL = process.env.NOTIFICATION_SERVICE_URL || 'http://notification-service.notification-service.svc.cluster.local:3002';

app.get('/health',  (req, res) => res.json({ status: 'ok' }));
app.get('/version', (req, res) => res.json({ service: 'api-gateway', version: '1.0.0' }));

app.use('/orders',        createProxyMiddleware({ target: ORDER_SERVICE_URL,        changeOrigin: true }));
app.use('/notifications', createProxyMiddleware({ target: NOTIFICATION_SERVICE_URL, changeOrigin: true }));
app.use('/order-version', createProxyMiddleware({ target: ORDER_SERVICE_URL,        changeOrigin: true, pathRewrite: { '^/order-version': '/version' } }));
app.use('/notif-version', createProxyMiddleware({ target: NOTIFICATION_SERVICE_URL, changeOrigin: true, pathRewrite: { '^/notif-version': '/version' } }));
app.use('/order-secrets', createProxyMiddleware({ target: ORDER_SERVICE_URL,        changeOrigin: true, pathRewrite: { '^/order-secrets': '/secrets' } }));

app.listen(PORT, () => console.log(`API Gateway running on port ${PORT}`));
