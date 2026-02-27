# Nonfunctional Requirements

> Extracted from the Cloud Platform Engineering Technical Assessment (Azure) specification.
> Includes all core requirements and stretch goals.
> See [constraints-and-assumptions.md](constraints-and-assumptions.md) for project constraints, assumptions, and deliverables.

---

## NFR-1: Security

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-1.1 | The system shall ensure that no Azure service is reachable from the public internet; all communication shall remain within the VNet or traverse the Azure private backbone via Private Endpoints. | Core |
| NFR-1.2 | The system shall enforce least-privilege NSG rules, permitting only the minimum traffic required for each subnet. | Core |
| NFR-1.3 | The system shall store all certificates and secrets in Azure Key Vault; no secret shall appear in source code or plain-text configuration. | Core |
| NFR-1.4 | The system shall enforce mutual TLS (mTLS) at the API layer for every client connection. | Core |
| NFR-1.5 | The system shall restrict network access to the Function App's Storage Account (e.g., deny public access, allow VNet access only). | Core |
| NFR-1.6 | The CI/CD pipeline shall authenticate to Azure using OIDC; no long-lived service principal secrets shall be stored in GitHub. | Core |
| NFR-1.7 | The system shall use Managed Identities for all service-to-service authentication, eliminating shared secrets between Azure resources. | Stretch |

## NFR-2: Auditability & Logging

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-2.1 | The system shall log all API requests with sufficient detail for audit purposes. | Core |
| NFR-2.2 | The system shall centralise all logs in a Log Analytics Workspace. | Core |
| NFR-2.3 | The system shall connect Application Insights to the Function App for telemetry and diagnostics. | Core |
| NFR-2.4 | The system shall configure diagnostic settings on all deployed resources to stream logs to the Log Analytics Workspace. | Stretch |

## NFR-3: Reliability & Monitoring

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-3.1 | The system shall provide basic health monitoring for the API. | Core |
| NFR-3.2 | The system shall define at least one Azure Monitor alert rule on a relevant metric (e.g., error rate, latency, or availability). | Core |

## NFR-4: Maintainability

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-4.1 | The Terraform codebase shall use logical file organisation (e.g., separate files for networking, compute, certificates). | Core |
| NFR-4.2 | The Terraform codebase shall follow clear, consistent resource naming conventions. | Core |
| NFR-4.3 | The Terraform codebase shall use `variables` and `locals` where appropriate to avoid excessive hard-coding. | Core |
| NFR-4.4 | The Terraform code shall pass `terraform fmt` formatting checks. | Core |
| NFR-4.5 | The Terraform code shall pass `terraform validate` syntax checks. | Core |

## NFR-5: Modularity & Reusability

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-5.1 | The system shall organise infrastructure code into reusable Terraform modules that can be shared across environments and projects. | Stretch |
| NFR-5.2 | The system shall support environment separation (Dev/Prod) via Terraform workspaces or a directory-based structure. | Stretch |

## NFR-6: Testability

| ID | Requirement | Priority |
|----|-------------|----------|
| NFR-6.1 | The system shall include automated infrastructure tests (using `terraform test` or Terratest) to validate resource correctness. | Stretch |
