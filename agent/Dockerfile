# syntax=docker/dockerfile:1.6
FROM python:3.12-slim

ARG TERRAFORM_VERSION=1.13.3
# @azure/mcp version pinned for reproducible builds. Bump when intentionally
# upgrading the pricing tool's MCP backend.
ARG AZURE_MCP_VERSION=latest
ARG NODE_MAJOR=20

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PORT=8088

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        git curl unzip ca-certificates gnupg lsb-release apt-transport-https \
 && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/tf.zip \
 && unzip /tmp/tf.zip -d /usr/local/bin \
 && rm /tmp/tf.zip \
 && chmod +x /usr/local/bin/terraform \
 && terraform version \
 && mkdir -p /etc/apt/keyrings \
 && curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
 && chmod go+r /etc/apt/keyrings/microsoft.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ bookworm main" \
      > /etc/apt/sources.list.d/azure-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends azure-cli \
 && az version \
 && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && node --version \
 && npm --version \
 && npm install -g "@azure/mcp@${AZURE_MCP_VERSION}" \
 && which azmcp \
 && azmcp --version || true \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --pre -r requirements.txt

COPY . /app

EXPOSE 8088

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request, sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8088/readiness', timeout=5).status == 200 else 1)" || exit 1

CMD ["python", "main.py"]
