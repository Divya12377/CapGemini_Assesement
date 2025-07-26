const express = require('express');
const app = express();
const port = 3000;

// Get environment from environment variable
const environment = process.env.ENVIRONMENT || 'unknown';
const appVersion = process.env.APP_VERSION || '1.0.0';

app.get('/', (req, res) => {
  res.json({
    message: `Hello from ${environment} environment!`,
    version: appVersion,
    environment: environment,
    timestamp: new Date().toISOString()
  });
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy', environment: environment });
});

app.get('/ready', (req, res) => {
  res.status(200).json({ status: 'ready', environment: environment });
});

// Add the /api/info endpoint that Jenkins expects
app.get('/api/info', (req, res) => {
  res.status(200).json({ 
    status: 'ok',
    environment: environment,
    version: appVersion,
    uptime: process.uptime(),
    timestamp: new Date().toISOString()
  });
});

app.listen(port, () => {
  console.log(`App running on port ${port} in ${environment} environment`);
});
