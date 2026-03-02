<#
.SYNOPSIS
    End-to-end smoke tests for the Azure Demo workload, run from the jumpbox.

.DESCRIPTION
    Validates the deployed application by exercising endpoints through the
    Application Gateway (AppGW) Private Endpoint for each configured
    environment (dev, prod).

    The AppGW is not Internet-facing.  Clients connect via a Private Endpoint
    registered as appgw.internal.contoso.com in the project private DNS zone.
    The AppGW enforces mTLS, routes by path to the correct APIM environment,
    and re-establishes TLS to the APIM backend.

    For each environment the following tests are run:

      1. DNS resolution - appgw.internal.contoso.com resolves to a private IP.
      2. Health endpoint - GET /api/<env>/health returns 200 with {"status":"healthy"}.
      3. Message endpoint (mTLS) - POST /api/<env>/message with client cert returns 200
         and the expected JSON payload.
      4. Validation - POST /api/<env>/message with missing/empty message returns 400.
      5. Malformed JSON - POST /api/<env>/message with invalid body returns 400.
      6. Missing client cert - request is rejected by AppGW (mTLS enforced at the
         listener; AppGW v2 returns HTTP 400 or drops the TLS handshake).
      7. Wrong HTTP method - GET /api/<env>/message returns 4xx.
      8. Alert trigger - deliberate 500 errors to trip the failure alert.

    Certificates are retrieved once from the first environment's Key Vault
    (the client cert and CA are project-wide, not environment-specific).

    mTLS is terminated at the Application Gateway.  APIM no longer validates
    client certificates; the AppGW forwards requests over backend HTTPS using
    the project CA-signed APIM certificate.

.NOTES
    Run from an elevated PowerShell prompt on the jumpbox.
    Requires: Azure CLI (az), PowerShell 5.1+, openssl on PATH.
#>

# -------------------------------------------------------------------------------
# CONFIGURATION - edit these values to match your deployment
# -------------------------------------------------------------------------------

# Environments to test (each entry must match a Terraform workspace).
# The first environment's Key Vault is used to retrieve the shared client cert.
$Environments = @(
    @{ Name = "dev";  Stamp = "1" },
    @{ Name = "prod"; Stamp = "1" }
)

# Workload name (matches the 'workload' local in Terraform)
$Workload = "wkld"

# Application Gateway hostname (resolved via private DNS within the VNet).
# Override with a specific IP or hostname if needed:
#   $AppGwHost = "10.100.130.5"
$AppGwHost = "appgw.internal.contoso.com"

# Key Vault name for certificate retrieval (first environment)
$KeyVaultName = "kv-${Workload}-$($Environments[0].Stamp)-$($Environments[0].Name)"

# Temp directory for downloaded certificates
$CertDir = "$env:TEMP\azure-demo-test-certs"

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
# PRE-FLIGHT - resolve AppGW hostname, download certs from Key Vault
# -------------------------------------------------------------------------------

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Azure Demo - Application Smoke Tests"   -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$envNames = ($Environments | ForEach-Object { $_.Name }) -join ", "
Write-Host "Environments : $envNames"
Write-Host "AppGW Host   : $AppGwHost"
Write-Host "Key Vault    : $KeyVaultName"
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
# OpenSSL is installed on the jumpbox by the Custom Script Extension (via Git for Windows).
Write-Host "Building PFX from client certificate..." -ForegroundColor Yellow
$pfxPath     = "$CertDir\client.pfx"
$pfxPassword = "test-smoke"

try {
    & openssl pkcs12 -export `
        -out $pfxPath `
        -inkey "$CertDir\client-key.pem" `
        -in "$CertDir\client-cert.pem" `
        -passout "pass:$pfxPassword" 2>&1 | Out-Null

    $certFlags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    $clientCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxPath, $pfxPassword, $certFlags)
    Write-Host "Client cert thumbprint: $($clientCert.Thumbprint)" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to build PFX. Ensure openssl is on PATH." -ForegroundColor Red
    Write-Host "       $_" -ForegroundColor Red
    exit 1
}

# -------------------------------------------------------------------------------
# SSL / CERT DIAGNOSTICS
# -------------------------------------------------------------------------------

Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host " SSL / Certificate Diagnostics"          -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host ""

# Cert/key modulus match
$certMod = & openssl x509 -noout -modulus -in "$CertDir\client-cert.pem" 2>&1
$keyMod  = & openssl rsa  -noout -modulus -in "$CertDir\client-key.pem" 2>&1
$modMatch = ($certMod -eq $keyMod)
Write-Host "Cert/Key modulus match: $modMatch" -ForegroundColor $(if ($modMatch) {"Green"} else {"Red"})
if (-not $modMatch) {
    Write-Host "  Cert: $($certMod.Substring(0,[Math]::Min(50,$certMod.Length)))..." -ForegroundColor Gray
    Write-Host "  Key:  $($keyMod.Substring(0,[Math]::Min(50,$keyMod.Length)))..." -ForegroundColor Gray
}

# Client cert details
Write-Host "Client cert subject : $($clientCert.Subject)" -ForegroundColor Gray
Write-Host "Client cert issuer  : $($clientCert.Issuer)" -ForegroundColor Gray
Write-Host "Client cert expires : $($clientCert.NotAfter)" -ForegroundColor Gray
Write-Host "Has private key     : $($clientCert.HasPrivateKey)" -ForegroundColor $(if ($clientCert.HasPrivateKey) {"Green"} else {"Red"})

# openssl s_client handshake test
Write-Host ""
Write-Host "TLS handshake via openssl s_client (AppGW PE)..." -ForegroundColor Yellow
try {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $sslOut = echo "Q" | & openssl s_client -connect "${AppGwHost}:443" -cert "$CertDir\client-cert.pem" -key "$CertDir\client-key.pem" -servername $AppGwHost -brief 2>&1
    $ErrorActionPreference = $prevEAP
    $sslText = $sslOut | Out-String
    $sslText.Split("`n") | Where-Object { $_ -match "CONNECTION|Protocol|Cipher|Verification|subject|issuer" } | ForEach-Object {
        Write-Host "  $_" -ForegroundColor Gray
    }
} catch {
    $ErrorActionPreference = $prevEAP
    Write-Host "  openssl s_client failed: $_" -ForegroundColor Red
}

# -------------------------------------------------------------------------------
# TLS / SESSION SETUP
# -------------------------------------------------------------------------------

# Trust the AppGW self-signed certificate (CN=appgw-core) for this session only.
# The AppGW presents its own server cert; the jumpbox does not have the project CA
# in its Trusted Root store by default.
# In production, install the CA cert into the Trusted Root store instead.
if (-not ([System.Net.ServicePointManager]::ServerCertificateValidationCallback)) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

# Enable TLS 1.2 and TLS 1.3 (TLS 1.3 = 12288; enum value may not exist in older .NET Framework)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]12288

# -------------------------------------------------------------------------------
# DNS RESOLUTION (shared across environments — single AppGW hostname)
# -------------------------------------------------------------------------------

Write-Host ""
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host " Running Tests"                           -ForegroundColor Cyan
Write-Host "----------------------------------------" -ForegroundColor Cyan
Write-Host ""

$appGwIsIp = $AppGwHost -match "^\d{1,3}(\.\d{1,3}){3}$"

if ($appGwIsIp) {
    Write-TestResult -TestName "DNS Resolution (AppGW PE)" -Success $true `
        -Detail "Skipped - AppGwHost is a raw IP address ($AppGwHost)"
} else {
    try {
        $dns        = Resolve-DnsName -Name $AppGwHost -ErrorAction Stop
        $resolvedIp = ($dns | Where-Object { $_.QueryType -eq "A" }).IPAddress | Select-Object -First 1
        # AppGW PE has a private IP; a public IP would indicate misconfiguration
        $isPrivate  = $resolvedIp -match "^10\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^192\.168\."
        Write-TestResult -TestName "DNS Resolution (AppGW PE)" -Success ($null -ne $resolvedIp -and $isPrivate) `
            -Detail "$AppGwHost -> $resolvedIp (private=$isPrivate)"
    }
    catch {
        Write-TestResult -TestName "DNS Resolution (AppGW PE)" -Success $false `
            -Detail "Failed to resolve $AppGwHost - $_"
    }
}

# ===============================================================================
# PER-ENVIRONMENT TESTS
# ===============================================================================

foreach ($env in $Environments) {
    $envName = $env.Name
    $BaseUrl = "https://${AppGwHost}/api/${envName}"

    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    Write-Host " Environment: $envName"                    -ForegroundColor Cyan
    Write-Host " Base URL   : $BaseUrl"                    -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    Write-Host ""

    # ---------------------------------------------------------------------------
    # Health Endpoint (mTLS required - AppGW enforces client cert on listener)
    # ---------------------------------------------------------------------------

    try {
        $healthUrl = "$BaseUrl/health"

        $webRequest = [System.Net.HttpWebRequest]::Create($healthUrl)
        $webRequest.Method  = "GET"
        $webRequest.Timeout = 30000
        $webRequest.ClientCertificates.Add($clientCert) | Out-Null

        $webResponse    = $webRequest.GetResponse()
        $reader         = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
        $healthResponse = $reader.ReadToEnd() | ConvertFrom-Json
        $reader.Close()
        $webResponse.Close()

        $healthOk = ($healthResponse.status -eq "healthy") -and ($null -ne $healthResponse.timestamp)
        Write-TestResult -TestName "[$envName] Health Endpoint (GET /health)" -Success $healthOk `
            -Detail "status=$($healthResponse.status), timestamp=$($healthResponse.timestamp)"
    }
    catch {
        $statusCode = if ($_.Exception.InnerException -is [System.Net.WebException]) {
            $_.Exception.InnerException.Response.StatusCode.value__
        } else { "N/A" }
        Write-TestResult -TestName "[$envName] Health Endpoint (GET /health)" -Success $false `
            -Detail "HTTP $statusCode - $_"
    }

    # ---------------------------------------------------------------------------
    # Message Endpoint - Happy Path (mTLS + valid payload)
    # ---------------------------------------------------------------------------

    try {
        $msgUrl   = "$BaseUrl/message"
        $testMsg  = "Hello from jumpbox smoke test ($envName)"
        $jsonBody = @{ message = $testMsg } | ConvertTo-Json

        $webRequest = [System.Net.HttpWebRequest]::Create($msgUrl)
        $webRequest.Method      = "POST"
        $webRequest.ContentType = "application/json"
        $webRequest.Timeout     = 30000
        $webRequest.ClientCertificates.Add($clientCert) | Out-Null

        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        $stream    = $webRequest.GetRequestStream()
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Close()

        $webResponse  = $webRequest.GetResponse()
        $reader       = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
        $responseBody = $reader.ReadToEnd() | ConvertFrom-Json
        $reader.Close()
        $webResponse.Close()

        $msgOk = (
            $responseBody.message -eq $testMsg -and
            $null -ne $responseBody.timestamp -and
            $null -ne $responseBody.request_id
        )
        Write-TestResult -TestName "[$envName] Message - Happy Path (POST /message)" -Success $msgOk `
            -Detail "message='$($responseBody.message)', request_id=$($responseBody.request_id)"
    }
    catch {
        $statusCode = if ($_.Exception.InnerException -is [System.Net.WebException]) {
            $_.Exception.InnerException.Response.StatusCode.value__
        } else { "N/A" }
        Write-TestResult -TestName "[$envName] Message - Happy Path (POST /message)" -Success $false `
            -Detail "HTTP $statusCode - $_"
    }

    # ---------------------------------------------------------------------------
    # Message Endpoint - Missing Message Field (expect 400)
    # ---------------------------------------------------------------------------

    try {
        $msgUrl   = "$BaseUrl/message"
        $jsonBody = @{ notmessage = "oops" } | ConvertTo-Json

        $webRequest = [System.Net.HttpWebRequest]::Create($msgUrl)
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
            Write-TestResult -TestName "[$envName] Message - Missing Field (expect 400)" -Success $false `
                -Detail "Expected 400 but received 2xx"
        }
        catch [System.Net.WebException] {
            $errResponse = $_.Exception.Response
            if ($null -eq $errResponse) { throw }
            $errStatusCode = [int]$errResponse.StatusCode
            $errReader = New-Object System.IO.StreamReader($errResponse.GetResponseStream())
            $errBody   = $errReader.ReadToEnd() | ConvertFrom-Json
            $errReader.Close()

            $validationOk = ($errStatusCode -eq 400) -and ($errBody.error.code -eq "INVALID_REQUEST")
            Write-TestResult -TestName "[$envName] Message - Missing Field (expect 400)" -Success $validationOk `
                -Detail "HTTP $errStatusCode, code=$($errBody.error.code)"
        }
    }
    catch {
        Write-TestResult -TestName "[$envName] Message - Missing Field (expect 400)" -Success $false `
            -Detail "$_"
    }

    # ---------------------------------------------------------------------------
    # Message Endpoint - Empty Message (expect 400)
    # ---------------------------------------------------------------------------

    try {
        $msgUrl   = "$BaseUrl/message"
        $jsonBody = @{ message = "   " } | ConvertTo-Json

        $webRequest = [System.Net.HttpWebRequest]::Create($msgUrl)
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
            Write-TestResult -TestName "[$envName] Message - Empty/Whitespace (expect 400)" -Success $false `
                -Detail "Expected 400 but received 2xx"
        }
        catch [System.Net.WebException] {
            $errResponse = $_.Exception.Response
            if ($null -eq $errResponse) { throw }
            $errStatusCode = [int]$errResponse.StatusCode
            $errReader     = New-Object System.IO.StreamReader($errResponse.GetResponseStream())
            $errBody       = $errReader.ReadToEnd() | ConvertFrom-Json
            $errReader.Close()

            $validationOk = ($errStatusCode -eq 400) -and ($errBody.error.code -eq "INVALID_REQUEST")
            Write-TestResult -TestName "[$envName] Message - Empty/Whitespace (expect 400)" -Success $validationOk `
                -Detail "HTTP $errStatusCode, code=$($errBody.error.code)"
        }
    }
    catch {
        Write-TestResult -TestName "[$envName] Message - Empty/Whitespace (expect 400)" -Success $false `
            -Detail "$_"
    }

    # ---------------------------------------------------------------------------
    # Message Endpoint - Malformed JSON (expect 400)
    # ---------------------------------------------------------------------------

    try {
        $msgUrl  = "$BaseUrl/message"
        $rawBody = "this is not json"

        $webRequest = [System.Net.HttpWebRequest]::Create($msgUrl)
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
            Write-TestResult -TestName "[$envName] Message - Malformed JSON (expect 400)" -Success $false `
                -Detail "Expected 400 but received 2xx"
        }
        catch [System.Net.WebException] {
            $errResponse = $_.Exception.Response
            if ($null -eq $errResponse) { throw }
            $errStatusCode = [int]$errResponse.StatusCode
            $errReader     = New-Object System.IO.StreamReader($errResponse.GetResponseStream())
            $errBody       = $errReader.ReadToEnd() | ConvertFrom-Json
            $errReader.Close()

            $malformedOk = ($errStatusCode -eq 400) -and ($errBody.error.code -eq "MALFORMED_JSON")
            Write-TestResult -TestName "[$envName] Message - Malformed JSON (expect 400)" -Success $malformedOk `
                -Detail "HTTP $errStatusCode, code=$($errBody.error.code)"
        }
    }
    catch {
        Write-TestResult -TestName "[$envName] Message - Malformed JSON (expect 400)" -Success $false `
            -Detail "$_"
    }

    # ---------------------------------------------------------------------------
    # Message Endpoint - No Client Certificate (expect mTLS rejection)
    #
    # mTLS is enforced at the Application Gateway listener.  Azure AppGW v2 may
    # either drop the TLS handshake or return HTTP 400.  Both confirm enforcement.
    # ---------------------------------------------------------------------------

    try {
        $msgUrl   = "$BaseUrl/message"
        $jsonBody = @{ message = "should be rejected" } | ConvertTo-Json

        # Deliberately omit client certificate
        $webRequest = [System.Net.HttpWebRequest]::Create($msgUrl)
        $webRequest.Method      = "POST"
        $webRequest.ContentType = "application/json"
        $webRequest.Timeout     = 30000

        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        $stream    = $webRequest.GetRequestStream()
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Close()

        try {
            $webResponse = $webRequest.GetResponse()
            $respStatusCode = [int]$webResponse.StatusCode
            $webResponse.Close()
            Write-TestResult -TestName "[$envName] Message - No Client Cert (expect mTLS rejection)" -Success $false `
                -Detail "Expected rejection but received HTTP $respStatusCode"
        }
        catch [System.Net.WebException] {
            $errResponse = $_.Exception.Response
            if ($null -ne $errResponse) {
                $errStatusCode = [int]$errResponse.StatusCode
                $mtlsEnforced = ($errStatusCode -eq 400)
                Write-TestResult -TestName "[$envName] Message - No Client Cert (expect mTLS rejection)" -Success $mtlsEnforced `
                    -Detail "HTTP $errStatusCode - AppGW rejected request without client cert"
            } else {
                Write-TestResult -TestName "[$envName] Message - No Client Cert (expect mTLS rejection)" -Success $true `
                    -Detail "Connection rejected at TLS layer (AppGW mTLS enforced): $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-TestResult -TestName "[$envName] Message - No Client Cert (expect mTLS rejection)" -Success $true `
            -Detail "Connection error (AppGW mTLS enforced): $_"
    }

    # ---------------------------------------------------------------------------
    # Message Endpoint - Wrong HTTP Method (expect 405 or 404)
    # ---------------------------------------------------------------------------

    try {
        $msgUrl = "$BaseUrl/message"

        $webRequest = [System.Net.HttpWebRequest]::Create($msgUrl)
        $webRequest.Method  = "GET"
        $webRequest.Timeout = 30000
        $webRequest.ClientCertificates.Add($clientCert) | Out-Null

        try {
            $webResponse = $webRequest.GetResponse()
            $webResponse.Close()
            Write-TestResult -TestName "[$envName] Message - GET Method (expect 4xx)" -Success $false `
                -Detail "Expected 4xx but received 2xx"
        }
        catch [System.Net.WebException] {
            $errResponse   = $_.Exception.Response
            $errStatusCode = [int]$errResponse.StatusCode
            $methodOk      = ($errStatusCode -ge 400 -and $errStatusCode -lt 500)
            Write-TestResult -TestName "[$envName] Message - GET Method (expect 4xx)" -Success $methodOk `
                -Detail "HTTP $errStatusCode"
        }
    }
    catch {
        Write-TestResult -TestName "[$envName] Message - GET Method (expect 4xx)" -Success $false `
            -Detail "$_"
    }

    # ---------------------------------------------------------------------------
    # Alert Trigger - Deliberate 500s via trip_server_side_error
    #
    # The func_failures alert fires when requests/failed exceeds the threshold
    # (default 5) within the evaluation window (default 15 min).
    # ---------------------------------------------------------------------------

    $alertIterations     = 8
    $alertSuccessCount   = 0
    $alertFailureDetails = @()

    Write-Host "[$envName] Sending $alertIterations deliberate 500 requests to trip failure alert..." -ForegroundColor Yellow

    for ($i = 1; $i -le $alertIterations; $i++) {
        try {
            $msgUrl   = "$BaseUrl/message"
            $jsonBody = @{ message = "alert-trigger-$i"; trip_server_side_error = $true } | ConvertTo-Json

            $webRequest = [System.Net.HttpWebRequest]::Create($msgUrl)
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
                $alertFailureDetails += "Iteration ${i}: Expected 500 but received 2xx"
            }
            catch [System.Net.WebException] {
                $errResponse = $_.Exception.Response
                if ($null -eq $errResponse) { throw }
                $errStatusCode = [int]$errResponse.StatusCode
                $errReader     = New-Object System.IO.StreamReader($errResponse.GetResponseStream())
                $errBody       = $errReader.ReadToEnd() | ConvertFrom-Json
                $errReader.Close()

                if ($errStatusCode -eq 500 -and $errBody.error.code -eq "DELIBERATE_ERROR") {
                    $alertSuccessCount++
                    Write-Host "  [$i/$alertIterations] HTTP 500 DELIBERATE_ERROR - OK" -ForegroundColor DarkGray
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
        "$alertSuccessCount/$alertIterations requests returned 500 DELIBERATE_ERROR"
    } else {
        "$alertSuccessCount/$alertIterations succeeded. Failures: $($alertFailureDetails -join '; ')"
    }

    Write-TestResult -TestName "[$envName] Alert Trigger - Deliberate 500s ($alertIterations requests)" `
        -Success $allTripped -Detail $detail
}

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
