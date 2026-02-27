# ── Build stage ───────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/azure-functions/python:4-python3.11 AS build

COPY requirements.txt /tmp/
RUN pip install --no-cache-dir --target /home/site/wwwroot/.python_packages/lib/site-packages \
    -r /tmp/requirements.txt

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/azure-functions/python:4-python3.11

ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true

COPY --from=build /home/site/wwwroot/.python_packages /home/site/wwwroot/.python_packages
COPY . /home/site/wwwroot
