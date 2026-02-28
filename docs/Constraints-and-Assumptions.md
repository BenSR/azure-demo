# Constraints & Assumptions

> Items extracted from the specification that are not system behaviours ("shall" statements) but instead represent fixed project boundaries, technology mandates, delivery obligations, and working assumptions.

---

## Technology Constraints

| ID | Constraint |
|----|------------|
| TC-1 | All infrastructure shall be provisioned using Terraform as the standardised IaC tool. |
| TC-2 | Certificates shall be generated using the Terraform `tls` provider (not an external CA or manual process). |
| TC-3 | Self-signed certificates are acceptable; commercial certificates or purchased domains shall not be used. |
| TC-4 | The CI/CD pipeline shall be implemented as a GitHub Actions workflow. |
| TC-5 | If APIM is chosen for the API layer, it shall use the Developer or Consumption tier. |
| TC-6 | The Azure Function may be written in any supported language. |

## Infrastructure Constraints

| ID | Constraint |
|----|------------|
| IC-1 | Remote state shall be considered for Terraform (e.g., Azure Blob Storage backend). Implementation is not required, but the approach must be documented or discussable. |
| IC-2 | Azure Free Tier or free credits should be used where possible to minimise costs. |

## Delivery Constraints (Deliverables)

| ID | Constraint |
|----|------------|
| DC-1 | The solution shall be pushed to a public GitHub repository. |
| DC-2 | A `README.md` shall include an architecture diagram. |
| DC-3 | A `README.md` shall include setup and deployment instructions. |
| DC-4 | A `README.md` shall include teardown instructions (including any manual steps beyond `terraform destroy`). |
| DC-5 | A `README.md` shall document all assumptions made during implementation. |
| DC-6 | A `README.md` shall include estimated Azure costs for running the infrastructure. |
| DC-7 | If AI coding assistants were used, the prompts shall be listed and a brief technical critique of the AI output shall be provided (e.g., insecure patterns, non-standard configurations). |
| DC-8 | Documentation shall describe how OIDC authentication is configured for the GitHub Actions workflow. |
| DC-9 | The solution shall be deployable end-to-end using the provided instructions. |
| DC-10 | Teardown shall be straightforward (`terraform destroy` plus any documented manual steps). |

## Assumptions

| ID | Assumption |
|----|------------|
| A-1 | A single Azure subscription and tenant are available for deployment. |
| A-2 | The implementer has Owner or Contributor access to the target Azure subscription. |
| A-3 | No existing VNet, Key Vault, or other shared infrastructure needs to be reused; all resources are greenfield. |
| A-4 | DNS resolution for Private Endpoints will use Azure-provided Private DNS Zones (no custom DNS server). |
| A-5 | The API will be consumed only by other services within the same VNet (no cross-VNet or on-premises peering required). |
| A-6 | A single region deployment is sufficient; multi-region is out of scope. |
| A-7 | No data residency or compliance requirements (e.g., GDPR, PCI-DSS) are in scope beyond what the spec explicitly states. |
| A-8 | The Function App will use Consumption or Premium plan; the specific plan choice is left to the implementer. |
| A-9 | GitHub repository secrets / environment configuration for OIDC are assumed to be set up manually (documented, not automated). |
