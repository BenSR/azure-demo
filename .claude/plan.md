# Plan: AppGW Private Endpoint + Multi-Environment Test Script

## Overview

Two changes:
1. **Lock AppGW behind a Private Endpoint** — add Private Link to the AppGW, create a PE in snet-shared-pe, register `appgw.internal.contoso.com` in the existing private DNS zone, block Internet inbound
2. **Multi-environment test script** — refactor Test-Application-Jumpbox.ps1 to test both dev and prod sequentially, connecting via `appgw.internal.contoso.com`

---

## Part 1: Application Gateway Private Link (Terraform phase3)

### 1a. `terraform/phase3/variables.tf` — Add PL subnet CIDR variable

- Add `appgw_pl_subnet_cidr` variable (default `"10.100.131.32/28"`) for the Private Link NAT subnet

### 1b. `terraform/phase3/network.tf` — New PL subnet + NSG changes

- Create `azurerm_subnet.appgw_pl` (`snet-appgw-pl`) in vnet-core for Private Link NAT IPs
- Change `appgw_in_allow_https` (priority 110): source `"Internet"` → PL subnet CIDR — rename to `allow-inbound-https-private-link`

### 1c. `terraform/phase3/appgw.tf` — Add Private Link + PE + DNS

- Add `private_link_configuration` block with `ip_configuration` pointing to `azurerm_subnet.appgw_pl.id`
- Add `private_link_configuration_name` to the existing public `frontend_ip_configuration`
- Create `azurerm_private_endpoint.appgw` in `snet-shared-pe` with `subresource_names = ["frontend-ip"]`
- Create `azurerm_private_dns_a_record.appgw` in the `internal.contoso.com` zone:
  - Name: `appgw` → resolves as `appgw.internal.contoso.com`
  - Records: PE NIC private IP
- Update header comments to reflect private architecture

### 1d. `terraform/phase3/outputs.tf` — Expose hostname + PE details

- Replace `appgw_public_ip` with `appgw_hostname` (`appgw.internal.contoso.com`)
- Update `api_urls` to use the hostname
- Add `appgw_private_endpoint_ip` output

---

## Part 2: Multi-Environment Test Script

### 2. `scripts/Test-Application-Jumpbox.ps1` — Full refactor

**Configuration:**
- Replace single `$Environment` / `$StampNumber` with an array:
  ```powershell
  $Environments = @(
      @{ Name = "dev";  Stamp = "1" },
      @{ Name = "prod"; Stamp = "1" }
  )
  ```
- Default `$AppGwHost = "appgw.internal.contoso.com"` (resolved via private DNS)
- Auto-detect fallback: query PE private IP via `az network private-endpoint show`

**Cert retrieval:**
- Certs are CA-level (same across environments). Download once from the first environment's KV
- Keep existing PFX build and diagnostics logic unchanged

**Test execution:**
- Wrap tests 1–9 in a `foreach ($env in $Environments)` loop
- Each iteration uses `$BaseUrl = "https://${AppGwHost}/api/$($env.Name)"`
- Test names prefixed with environment: `"[dev] Health Endpoint"`, `"[prod] Message - Happy Path"`, etc.
- Accumulate results across all environments

**Summary:**
- Single combined summary table showing all environments
- Exit code 1 if any test in any environment failed
