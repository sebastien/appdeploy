# appdeploy - Application Deployment Tool

## Overview

appdeploy is a command-line tool for managing application deployments. It provides a simple interface for packaging, deploying, and managing applications across different environments.

## Installation

### From Source

```bash
# Clone the repository
git clone https://github.com/yourusername/appdeploy.git
cd appdeploy

# Build and install
make install
```

### Requirements

- bash (version 4.0 or later)
- shc (shell script compiler)
- pandoc (for documentation generation)
- shellcheck (for linting)

## Usage

### Basic Commands

```bash
# Show help
appdeploy --help

# Show version
appdeploy --version

# Package an application
appdeploy package /path/to/app

# Deploy an application
appdeploy deploy /path/to/package

# List deployed applications
appdeploy list

# Remove a deployed application
appdeploy remove <app-name>
```

### Advanced Options

```bash
# Package with specific configuration
appdeploy package --config /path/to/config.yaml /path/to/app

# Deploy to specific environment
appdeploy deploy --env production /path/to/package

# Force redeploy
appdeploy deploy --force /path/to/package
```

## Configuration

appdeploy uses a YAML configuration file for deployment settings. Here's a sample configuration:

```yaml
# config.yaml
app_name: "my-application"
version: "1.0.0"
environments:
  - name: "development"
    host: "dev.example.com"
    port: 8080
    user: "deploy"
  - name: "production"
    host: "prod.example.com"
    port: 80
    user: "deploy"
deployment:
  strategy: "rolling"
  timeout: 300
  health_check: "/health"
```

## Environment Variables

appdeploy respects the following environment variables:

- `APPDEPLOY_CONFIG`: Path to configuration file (default: `./appdeploy.yaml`)
- `APPDEPLOY_ENV`: Default environment name
- `APPDEPLOY_DEBUG`: Enable debug logging (set to `1`)

## Examples

### Simple Deployment

```bash
# Package and deploy a simple web application
appdeploy package ./my-web-app
appdeploy deploy --env staging dist/my-web-app.tar.gz
```

### Multi-environment Deployment

```bash
# Deploy to multiple environments
for env in dev staging prod; do
  appdeploy deploy --env $env dist/my-app.tar.gz
done
```

### Continuous Deployment

```bash
# Example CI/CD pipeline step
#!/bin/bash
set -e

# Build application
npm run build

# Package with appdeploy
appdeploy package --config deploy-config.yaml ./build

# Deploy to staging
appdeploy deploy --env staging dist/app.tar.gz

# Run smoke tests
if curl -s "https://staging.example.com/health" | grep -q "ok"; then
  # Deploy to production
  appdeploy deploy --env production dist/app.tar.gz
fi
```

## Troubleshooting

### Common Issues

**Issue: "Command not found" after installation**

Ensure that the installation directory is in your PATH:
```bash
export PATH=$PATH:~/.local/bin
```

**Issue: Permission denied during deployment**

Make sure you have the correct SSH keys configured:
```bash
ssh-copy-id deploy@target-host
```

**Issue: Missing dependencies**

Install required tools:
```bash
# On Ubuntu/Debian
sudo apt-get install shc pandoc shellcheck

# On macOS
brew install shc pandoc shellcheck
```

## License

appdeploy is released under the MIT License. See LICENSE.md for details.

## Support

For issues, questions, or contributions, please visit the GitHub repository:
https://github.com/sebastien/appdeploy
