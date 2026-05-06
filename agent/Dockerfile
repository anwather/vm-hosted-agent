# syntax=docker/dockerfile:1.6
FROM mcr.microsoft.com/mirror/docker/library/python:3.12-slim

ARG TERRAFORM_VERSION=1.9.8

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PORT=8088

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        git curl unzip ca-certificates gnupg \
 && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/tf.zip \
 && unzip /tmp/tf.zip -d /usr/local/bin \
 && rm /tmp/tf.zip \
 && chmod +x /usr/local/bin/terraform \
 && terraform version \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --pre -r requirements.txt

COPY . /app

EXPOSE 8088

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request, sys; \
sys.exit(0 if urllib.request.urlopen('http://localhost:8088/health', timeout=5).status == 200 else 1)" || exit 1

CMD ["python", "main.py"]
