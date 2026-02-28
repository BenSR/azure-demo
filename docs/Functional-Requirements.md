# Functional Requirements

> Extracted from the Cloud Platform Engineering Technical Assessment (Azure) specification.
> Includes all core requirements and stretch goals.
> See [constraints-and-assumptions.md](constraints-and-assumptions.md) for project constraints, assumptions, and deliverables.

---

## FR-1: Networking

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1.1 | The system shall provision a Virtual Network (VNet) with at least two subnets. | Core |
| FR-1.2 | The system shall attach a Network Security Group (NSG) to each subnet with least-privilege inbound and outbound rules. | Core |
| FR-1.3 | The system shall provision Private Endpoints for all consumed Azure services so that traffic remains on the Azure private backbone. | Core |
| FR-1.4 | The system shall restrict API access to clients within the VNet only, with no public internet exposure. | Core |
| FR-1.5 | The system shall deploy an Application Gateway to handle ingress traffic into the VNet. | Stretch |

## FR-2: Compute — Azure Function

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-2.1 | The system shall deploy an Azure Function App. | Core |
| FR-2.2 | The Function shall accept HTTP POST requests with a JSON payload containing a `message` field. | Core |
| FR-2.3 | The Function shall validate the incoming payload and reject requests with a missing or invalid `message` field, returning an appropriate error response. | Core |
| FR-2.4 | The Function shall return a JSON response containing the original `message`, a `timestamp`, and the `request ID`. | Core |
| FR-2.5 | The Function shall handle errors gracefully by returning appropriate HTTP status codes and structured error bodies. | Core |
| FR-2.6 | The Function App shall be integrated with the VNet via VNet integration. | Core |

## FR-3: API Layer

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-3.1 | The system shall expose the Function through an API layer using either Azure API Management (APIM) or an Azure Function with a Private Endpoint. | Core |
| FR-3.2 | The API layer shall be configured for internal-only access (no public endpoint). | Core |

## FR-4: Certificate Management & mTLS

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-4.1 | The system shall generate a self-signed Certificate Authority (CA) certificate. | Core |
| FR-4.2 | The system shall generate a client certificate signed by the CA. | Core |
| FR-4.3 | The system shall store all generated certificates and private keys in Azure Key Vault. | Core |
| FR-4.4 | The system shall configure mutual TLS (mTLS) on the API layer using the CA certificate as the truststore. | Core |
| FR-4.5 | The system shall require every client to present a valid CA-signed client certificate when calling the API. | Core |

## FR-5: Observability

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-5.1 | The system shall connect an Application Insights instance to the Function App for telemetry collection. | Core |
| FR-5.2 | The system shall deploy a Log Analytics Workspace for centralised log aggregation. | Core |
| FR-5.3 | The system shall define at least one Azure Monitor alert rule on a relevant metric (e.g., error rate, latency, or availability). | Core |
| FR-5.4 | The system shall log all API requests for audit purposes. | Core |
| FR-5.5 | The system shall configure diagnostic settings on all deployed resources to stream logs to the Log Analytics Workspace. | Stretch |

## FR-6: Supporting Infrastructure

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-6.1 | The system shall deploy a Storage Account for the Function App with network access restricted to the VNet. | Core |
| FR-6.2 | The system shall deploy an Azure Key Vault instance for secure management of secrets and certificates. | Core |

## FR-7: Health Monitoring

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-7.1 | The system shall implement basic health monitoring for the API (e.g., availability test or health-check endpoint). | Core |

## FR-8: CI/CD Pipeline

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-8.1 | The CI/CD pipeline shall validate Terraform formatting on every run. | Core |
| FR-8.2 | The CI/CD pipeline shall validate Terraform syntax on every run. | Core |
| FR-8.3 | The CI/CD pipeline shall execute `terraform plan` and surface the plan output. | Core |
| FR-8.4 | The CI/CD pipeline shall authenticate to Azure using OpenID Connect (OIDC). | Core |

## FR-9: Identity & Access

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-9.1 | The system shall use Managed Identities for all service-to-service communication, eliminating shared secrets between Azure resources. | Stretch |

## FR-10: Infrastructure Testing

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-10.1 | The system shall include automated infrastructure tests (using `terraform test` or Terratest) to validate resource correctness. | Stretch |

## FR-11: Environment Separation

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-11.1 | The system shall support environment separation (e.g., Dev/Prod) via Terraform workspaces or a directory-based structure. | Stretch |

## FR-12: Reusable Module Structure

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-12.1 | The system shall organise Terraform code into reusable modules that can be composed across environments and projects. | Stretch |
