// app/src/server.js
const express = require('express');
const app = express();
const port = process.env.PORT || 3000;
const version = process.env.APP_VERSION || '1.0.0';
const environment = process.env.ENVIRONMENT || 'blue';

app.use(express.json());

// Health check endpoint
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    version: version,
    environment: environment,
    timestamp: new Date().toISOString()
  });
});

// Readiness probe
app.get('/ready', (req, res) => {
  res.status(200).json({
    status: 'ready',
    version: version,
    environment: environment
  });
});

// Main application endpoint
app.get('/', (req, res) => {
  res.json({
    message: `Hello from ${environment} environment!`,
    version: version,
    environment: environment,
    hostname: require('os').hostname(),
    timestamp: new Date().toISOString()
  });
});

// API endpoint
app.get('/api/info', (req, res) => {
  res.json({
    application: 'Blue-Green Demo App',
    version: version,
    environment: environment,
    node_version: process.version,
    uptime: process.uptime(),
    memory_usage: process.memoryUsage()
  });
});

// Error endpoint for testing
app.get('/error', (req, res) => {
  res.status(500).json({
    error: 'Intentional error for testing',
    environment: environment
  });
});

app.listen(port, () => {
  console.log(`App running on port ${port}`);
  console.log(`Version: ${version}`);
  console.log(`Environment: ${environment}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down gracefully');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('SIGINT received, shutting down gracefully');
  process.exit(0);
});
