<#
.SYNOPSIS
    End-to-end smoke tests for the Azure Demo workload, run from the jumpbox.

.DESCRIPTION
    Validates the deployed application by exercising the APIM gateway endpoints
    (health check, echo API with mTLS) from inside the VNet.

    The jumpbox sits on snet-jumpbox and can reach APIM (internal VNet mode)
    and all Private Endpoints.  Tests cover:

      1. DNS resolution — APIM gateway hostname resolves to a private IP.
      2. Health endpoint — GET /api/health returns 200 with {"status":"healthy"}.
      3. Echo endpoint (mTLS) — POST /api/echo with client cert returns 200
         and the expected JSON payload.
      4. Validation — POST /api/echo with missing/empty message returns 400.
      5. Malformed JSON — POST /api/echo with invalid body returns 400.
      6. Missing client cert — POST /api/echo without a client cert is rejected (403).

    Certificates are retrieved from Key Vault using the Azure CLI (the jumpbox
    identity or logged-in user must have Key Vault Secrets User on the stamp KV).

.NOTES
    Run from an elevated PowerShell prompt on the jumpbox.
    Requires: Azure CLI (az), PowerShell 5.1+.
#>

# -------------------------------------------------------------------------------
# CONFIGURATION — edit these values to match your deployment
# -------------------------------------------------------------------------------

# Environment name (must match the Terraform workspace: "dev" or "prod")
$Environment     = "dev"

# Workload name (matches the 'workload' local in Terraform)
$Workload        = "wkld"

# Stamp number to test (e.g. "1")
$StampNumber     = "1"

# APIM gateway hostname (from Terraform output: apim_gateway_url)
# Internal VNet mode — resolves to a private IP within the VNet.
# Example: apim-wkld-shared-dev.azure-api.net
$ApimGatewayHost = "apim-${Workload}-shared-${Environment}.azure-api.net"

# APIM API path prefix (matches azurerm_api_management_api.wkld.path)
$ApiPath         = "api"

# Key Vault name for the stamp (matches kv-<workload>-<stamp>-<env>)
$KeyVaultName    = "kv-${Workload}-${StampNumber}-${Environment}"

# Temp directory for downloaded certificates
$CertDir         = "$env:TEMP\azure-demo-test-certs"

# -------------------------------------------------------------------------------
# HELPERS
# -------------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$passed = 0
$failed = 0
$results = @()

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Success,
        [string]$Detail = ""
    )
    $icon = if ($Success) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Success) { "Green" } else { "Red" }
    Write-Host "$icon $TestName" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Gray }
    $script:results += [PSCustomObject]@{
        Test   = $TestName
        Result = if ($Success) { "PASS" } else { "FAIL" }
        Detail = $Detail
    }
    if ($Success) { $script:passed++ } else { $script:failed++ }
}

# -------------------------------------------------------------------------------
# PRE-FLIGHT — download certs from Key Vault
# -------------------------------------------------------------------------------

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Azure Demo — Application Smoke Tests"   -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Environment : $Environment"
Write-Host "Stamp       : $StampNumber"
Write-Host "APIM Host   : $ApimGatewayHost"
Write-Host "Key Vault   : $KeyVaultName"
Write-Host ""

# Ensure temp cert directory exists
if (-not (Test-Path $CertDir)) { New-Item -ItemType Directory -Path $CertDir -Force | Out-Null }

Write-Host "Retrieving certificates from Key Vault..." -ForegroundColor Yellow

try {
    # Client certificate PEM
    $clientCertPem = az keyvault secret show `
        --vault-name $KeyVaultName `
        --name "client-cert-pem" `
        --query "value" -o tsv
    $clientCertPem | Out-File -FilePath "$CertDir\client-cert.pem" -Encoding ASCII -Force

    # Client private key PEM
    $clientKeyPem = az keyvault secret show `
        --vault-name $KeyVaultName `
        --name "client-key-pem" `
        --query "value" -o tsv
    $clientKeyPem | Out-File -FilePath "$CertDir\client-key.pem" -Encoding ASCII -Force

    # CA certificate PEM (for trust validation)
    $caCertPem = az keyvault secret show `
        --vault-name $KeyVaultName `
        --name "ca-cert-pem" `
        --query "value" -o tsv
    $caCertPem | Out-File -FilePath "$CertDir\ca-cert.pem" -Encoding ASCII -Force

    Write-Host "Certificates retrieved successfully." -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to retrieve certificates from Key Vault." -ForegroundColor Red
    Write-Host "       Ensure you are logged in (az login) and have Key Vault Secrets User role." -ForegroundColor Red
    Write-Host "       $_" -ForegroundColor Red
    exit 1
}

# Build a PFX from the client cert + key so .NET HttpClient can use it.
# OpenSSL is expected on the jumpbox (ships with Git for Windows / Win11).
Write-Host "Building PFX from client certificate..." -ForegroundColor Yellow
$pfxPath     = "$CertDir\client.pfx"
$pfxPassword = "test-smoke"

try {
    & openssl pkcs12 -export `
        -out $pfxPath `
        -inkey "$CertDir\client-key.pem" `
        -in "$CertDir\client-cert.pem" `
        -passout "pass:$pfxPassword" 2>&1 | Out-Null

    $clientCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        $pfxPath, $pfxPassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
    )
    Write-Host "Client cert thumbprint: $($clientCert.Thumbprint)" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to build PFX. Ensure openssl is on PATH." -ForegroundColor Red
    Write-Host "       $_" -ForegroundColor Red
    exit 1
}

# -------------------------------------------------------------------------------
# BASE URL
# -------------------------------------------------------------------------------

$BaseUrl = "https://${ApimGatewayHost}/${ApiPath}"

# Trust the self-signed CA for this session (APIM uses an Azure-managed cert
# on its gateway, but if the internal DNS returns a self-signed cert, we need
# to allow it).  This callback trusts all certs for this process only.
# In production, install the CA cert into the Trusted Root store instead.
if (-not ([System.Net.ServicePointManager]::ServerCertificateValidationCallback)) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

# Force TLS 1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

Write-Host ""
Write-Host "Base URL: $BaseUrl"
Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host " Running Tests"                           -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host ""

# -------------------------------------------------------------------------------
# TEST 1: DNS Resolution
# -------------------------------------------------------------------------------

try {
    $dns = Resolve-DnsName -Name $ApimGatewayHost -ErrorAction Stop
    $privateIp = ($dns | Where-Object { $_.QueryType -eq "A" }).IPAddress
    $isPrivate = $privateIp -match "^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^192\.168\."
    Write-TestResult -TestName "DNS Resolution" -Success $isPrivate `
        -Detail "$ApimGatewayHost -> $privateIp (private=$isPrivate)"
}
catch {
    Write-TestResult -TestName "DNS Resolution" -Success $false `
        -Detail "Failed to resolve $ApimGatewayHost — $_"
}

# -------------------------------------------------------------------------------
# TEST 2: Health Endpoint (no mTLS required)
# -------------------------------------------------------------------------------

try {
    $healthUrl = "$BaseUrl/health"
    $healthResponse = Invoke-RestMethod -Uri $healthUrl -Method GET -TimeoutSec 30
    $healthOk = ($healthResponse.status -eq "healthy") -and ($null -ne $healthResponse.timestamp)
    Write-TestResult -TestName "Health Endpoint (GET /api/health)" -Success $healthOk `
        -Detail "status=$($healthResponse.status), timestamp=$($healthResponse.timestamp)"
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    Write-TestResult -TestName "Health Endpoint (GET /api/health)" -Success $false `
        -Detail "HTTP $statusCode — $_"
}

# -------------------------------------------------------------------------------
# TEST 3: Echo Endpoint — Happy Path (mTLS + valid payload)
# -------------------------------------------------------------------------------

try {
    $echoUrl  = "$BaseUrl/echo"
    $testMsg  = "Hello from jumpbox smoke test"
    $jsonBody = @{ message = $testMsg } | ConvertTo-Json

    # Use HttpWebRequest for client cert support
    $webRequest = [System.Net.HttpWebRequest]::Create($echoUrl)
    $webRequest.Method      = "POST"
    $webRequest.ContentType = "application/json"
    $webRequest.Timeout     = 30000
    $webRequest.ClientCertificates.Add($clientCert) | Out-Null

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    $stream    = $webRequest.GetRequestStream()
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Close()

    $webResponse = $webRequest.GetResponse()
    $reader      = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
    $responseBody = $reader.ReadToEnd() | ConvertFrom-Json
    $reader.Close()
    $webResponse.Close()

    $echoOk = (
        $responseBody.message -eq $testMsg -and
        $null -ne $responseBody.timestamp -and
        $null -ne $responseBody.request_id
    )
    Write-TestResult -TestName "Echo Endpoint — Happy Path (POST /api/echo)" -Success $echoOk `
        -Detail "message='$($responseBody.message)', request_id=$($responseBody.request_id)"
}
catch {
    $statusCode = if ($_.Exception.InnerException -is [System.Net.WebException]) {
        $_.Exception.InnerException.Response.StatusCode.value__
    } else { "N/A" }
    Write-TestResult -TestName "Echo Endpoint — Happy Path (POST /api/echo)" -Success $false `
        -Detail "HTTP $statusCode — $_"
}

# -------------------------------------------------------------------------------
# TEST 4: Echo Endpoint — Missing Message Field (expect 400)
# -------------------------------------------------------------------------------

try {
    $echoUrl  = "$BaseUrl/echo"
    $jsonBody = @{ notmessage = "oops" } | ConvertTo-Json

    $webRequest = [System.Net.HttpWebRequest]::Create($echoUrl)
    $webRequest.Method      = "POST"
    $webRequest.ContentType = "application/json"
    $webRequest.Timeout     = 30000
    $webRequest.ClientCertificates.Add($clientCert) | Out-Null

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    $stream    = $webRequest.GetRequestStream()
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Close()

    # Expect a 400 — GetResponse() will throw on non-2xx
    try {
        $webResponse = $webRequest.GetResponse()
        $webResponse.Close()
        # If we get here, 2xx was returned — that's wrong
        Write-TestResult -TestName "Echo — Missing Message (expect 400)" -Success $false `
            -Detail "Expected 400 but received 2xx"
    }
    catch [System.Net.WebException] {
        $errResponse = $_.Exception.Response
        $errStatusCode = [int]$errResponse.StatusCode
        $errReader = New-Object System.IO.StreamReader($errResponse.GetResponseStream())
        $errBody   = $errReader.ReadToEnd() | ConvertFrom-Json
        $errReader.Close()

        $validationOk = ($errStatusCode -eq 400) -and ($errBody.error.code -eq "INVALID_REQUEST")
        Write-TestResult -TestName "Echo — Missing Message (expect 400)" -Success $validationOk `
            -Detail "HTTP $errStatusCode, code=$($errBody.error.code)"
    }
}
catch {
    Write-TestResult -TestName "Echo — Missing Message (expect 400)" -Success $false `
        -Detail "$_"
}

# -------------------------------------------------------------------------------
# TEST 5: Echo Endpoint — Empty Message (expect 400)
# -------------------------------------------------------------------------------

try {
    $echoUrl  = "$BaseUrl/echo"
    $jsonBody = @{ message = "   " } | ConvertTo-Json

    $webRequest = [System.Net.HttpWebRequest]::Create($echoUrl)
    $webRequest.Method      = "POST"
    $webRequest.ContentType = "application/json"
    $webRequest.Timeout     = 30000
    $webRequest.ClientCertificates.Add($clientCert) | Out-Null

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    $stream    = $webRequest.GetRequestStream()
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Close()

    try {
        $webResponse = $webRequest.GetResponse()
        $webResponse.Close()
        Write-TestResult -TestName "Echo — Empty/Whitespace Message (expect 400)" -Success $false `
            -Detail "Expected 400 but received 2xx"
    }
    catch [System.Net.WebException] {
        $errResponse   = $_.Exception.Response
        $errStatusCode = [int]$errResponse.StatusCode
        $errReader     = New-Object System.IO.StreamReader($errResponse.GetResponseStream())
        $errBody       = $errReader.ReadToEnd() | ConvertFrom-Json
        $errReader.Close()

        $validationOk = ($errStatusCode -eq 400) -and ($errBody.error.code -eq "INVALID_REQUEST")
        Write-TestResult -TestName "Echo — Empty/Whitespace Message (expect 400)" -Success $validationOk `
            -Detail "HTTP $errStatusCode, code=$($errBody.error.code)"
    }
}
catch {
    Write-TestResult -TestName "Echo — Empty/Whitespace Message (expect 400)" -Success $false `
        -Detail "$_"
}

# -------------------------------------------------------------------------------
# TEST 6: Echo Endpoint — Malformed JSON (expect 400)
# -------------------------------------------------------------------------------

try {
    $echoUrl  = "$BaseUrl/echo"
    $rawBody  = "this is not json"

    $webRequest = [System.Net.HttpWebRequest]::Create($echoUrl)
    $webRequest.Method      = "POST"
    $webRequest.ContentType = "application/json"
    $webRequest.Timeout     = 30000
    $webRequest.ClientCertificates.Add($clientCert) | Out-Null

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($rawBody)
    $stream    = $webRequest.GetRequestStream()
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Close()

    try {
        $webResponse = $webRequest.GetResponse()
        $webResponse.Close()
        Write-TestResult -TestName "Echo — Malformed JSON (expect 400)" -Success $false `
            -Detail "Expected 400 but received 2xx"
    }
    catch [System.Net.WebException] {
        $errResponse   = $_.Exception.Response
        $errStatusCode = [int]$errResponse.StatusCode
        $errReader     = New-Object System.IO.StreamReader($errResponse.GetResponseStream())
        $errBody       = $errReader.ReadToEnd() | ConvertFrom-Json
        $errReader.Close()

        $malformedOk = ($errStatusCode -eq 400) -and ($errBody.error.code -eq "MALFORMED_JSON")
        Write-TestResult -TestName "Echo — Malformed JSON (expect 400)" -Success $malformedOk `
            -Detail "HTTP $errStatusCode, code=$($errBody.error.code)"
    }
}
catch {
    Write-TestResult -TestName "Echo — Malformed JSON (expect 400)" -Success $false `
        -Detail "$_"
}

# -------------------------------------------------------------------------------
# TEST 7: Echo Endpoint — No Client Certificate (expect 403)
# -------------------------------------------------------------------------------

try {
    $echoUrl  = "$BaseUrl/echo"
    $jsonBody = @{ message = "should be rejected" } | ConvertTo-Json

    # Deliberately omit client certificate
    $webRequest = [System.Net.HttpWebRequest]::Create($echoUrl)
    $webRequest.Method      = "POST"
    $webRequest.ContentType = "application/json"
    $webRequest.Timeout     = 30000
    # No ClientCertificates.Add()

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
    $stream    = $webRequest.GetRequestStream()
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    $stream.Close()

    try {
        $webResponse = $webRequest.GetResponse()
        $respStatusCode = [int]$webResponse.StatusCode
        $webResponse.Close()
        # APIM should reject with 403 — if we get 200, mTLS is not enforced
        Write-TestResult -TestName "Echo — No Client Cert (expect 403)" -Success $false `
            -Detail "Expected 403 but received $respStatusCode — mTLS may not be enforced"
    }
    catch [System.Net.WebException] {
        $errResponse   = $_.Exception.Response
        $errStatusCode = [int]$errResponse.StatusCode
        $noCertOk      = ($errStatusCode -eq 403)
        Write-TestResult -TestName "Echo — No Client Cert (expect 403)" -Success $noCertOk `
            -Detail "HTTP $errStatusCode (expected 403)"
    }
}
catch {
    # Connection-level rejection (TLS handshake failure) is also acceptable
    # — APIM may terminate the connection before returning an HTTP status.
    $isHandshakeFailure = $_.Exception.Message -match "handshake|SSL|TLS|closed"
    Write-TestResult -TestName "Echo — No Client Cert (expect 403)" -Success $isHandshakeFailure `
        -Detail "Connection error (acceptable if TLS handshake rejected): $_"
}

# -------------------------------------------------------------------------------
# TEST 8: Echo Endpoint — Wrong HTTP Method (expect 405 or 404)
# -------------------------------------------------------------------------------

try {
    $echoUrl = "$BaseUrl/echo"

    $webRequest = [System.Net.HttpWebRequest]::Create($echoUrl)
    $webRequest.Method  = "GET"
    $webRequest.Timeout = 30000
    $webRequest.ClientCertificates.Add($clientCert) | Out-Null

    try {
        $webResponse = $webRequest.GetResponse()
        $webResponse.Close()
        Write-TestResult -TestName "Echo — GET Method (expect 4xx)" -Success $false `
            -Detail "Expected 4xx but received 2xx"
    }
    catch [System.Net.WebException] {
        $errResponse   = $_.Exception.Response
        $errStatusCode = [int]$errResponse.StatusCode
        $methodOk      = ($errStatusCode -ge 400 -and $errStatusCode -lt 500)
        Write-TestResult -TestName "Echo — GET Method (expect 4xx)" -Success $methodOk `
            -Detail "HTTP $errStatusCode"
    }
}
catch {
    Write-TestResult -TestName "Echo — GET Method (expect 4xx)" -Success $false `
        -Detail "$_"
}

# -------------------------------------------------------------------------------
# TEST 9: Alert Trigger — Deliberate 500s via trip_server_side_error
#
# The func_failures alert fires when requests/failed exceeds the threshold
# (default 5) within the evaluation window (default 15 min).  We send enough
# 500-producing requests to guarantee the alert trips.
# -------------------------------------------------------------------------------

$alertIterations       = 8   # comfortably above the default threshold of 5
$alertSuccessCount     = 0
$alertFailureDetails   = @()

Write-Host "Sending $alertIterations deliberate 500 requests to trip failure alert..." -ForegroundColor Yellow

for ($i = 1; $i -le $alertIterations; $i++) {
    try {
        $echoUrl  = "$BaseUrl/echo"
        $jsonBody = @{ message = "alert-trigger-$i"; trip_server_side_error = $true } | ConvertTo-Json

        $webRequest = [System.Net.HttpWebRequest]::Create($echoUrl)
        $webRequest.Method      = "POST"
        $webRequest.ContentType = "application/json"
        $webRequest.Timeout     = 30000
        $webRequest.ClientCertificates.Add($clientCert) | Out-Null

        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        $stream    = $webRequest.GetRequestStream()
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Close()

        try {
            $webResponse = $webRequest.GetResponse()
            $webResponse.Close()
            # 2xx is unexpected — the flag should have caused a 500
            $alertFailureDetails += "Iteration ${i}: Expected 500 but received 2xx"
        }
        catch [System.Net.WebException] {
            $errResponse   = $_.Exception.Response
            $errStatusCode = [int]$errResponse.StatusCode
            $errReader     = New-Object System.IO.StreamReader($errResponse.GetResponseStream())
            $errBody       = $errReader.ReadToEnd() | ConvertFrom-Json
            $errReader.Close()

            if ($errStatusCode -eq 500 -and $errBody.error.code -eq "DELIBERATE_ERROR") {
                $alertSuccessCount++
                Write-Host "  [$i/$alertIterations] HTTP 500 DELIBERATE_ERROR — OK" -ForegroundColor DarkGray
            }
            else {
                $alertFailureDetails += "Iteration ${i}: HTTP $errStatusCode, code=$($errBody.error.code)"
            }
        }
    }
    catch {
        $alertFailureDetails += "Iteration ${i}: $_"
    }

    # Brief pause to avoid request coalescing in telemetry pipeline
    Start-Sleep -Milliseconds 500
}

$allTripped = ($alertSuccessCount -eq $alertIterations)
$detail     = if ($allTripped) {
    "$alertSuccessCount/$alertIterations requests returned 500 DELIBERATE_ERROR — failure alert threshold exceeded"
} else {
    "$alertSuccessCount/$alertIterations succeeded. Failures: $($alertFailureDetails -join '; ')"
}

Write-TestResult -TestName "Alert Trigger — Deliberate 500s ($alertIterations requests)" `
    -Success $allTripped -Detail $detail

# -------------------------------------------------------------------------------
# SUMMARY
# -------------------------------------------------------------------------------

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Test Summary"                            -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$results | Format-Table -AutoSize

$totalColor = if ($failed -eq 0) { "Green" } else { "Red" }
Write-Host "Total: $($passed + $failed)  Passed: $passed  Failed: $failed" -ForegroundColor $totalColor
Write-Host ""

# -------------------------------------------------------------------------------
# CLEANUP
# -------------------------------------------------------------------------------

Write-Host "Cleaning up temp certificates..." -ForegroundColor Yellow
Remove-Item -Path $CertDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Done." -ForegroundColor Green
Write-Host ""

# Exit with non-zero if any test failed (useful for CI/CD)
if ($failed -gt 0) { exit 1 }
