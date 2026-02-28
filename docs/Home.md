# Azure Demo — Documentation

Welcome to the Azure Demo project wiki. This documentation covers the design, infrastructure, application, and CI/CD approach for a secure, privately-networked Azure Function App fronted by API Management.

---

## Requirements

- [Constraints and Assumptions](Constraints-and-Assumptions) — fixed project boundaries, technology mandates, and working assumptions
- [Functional Requirements](Functional-Requirements) — core requirements and stretch goals (FR-1 through FR-12)
- [Nonfunctional Requirements](Nonfunctional-Requirements) — security, auditability, reliability, maintainability, modularity, testability

## Infrastructure Design

- [Infrastructure Solution Design](Infrastructure-Solution-Design) — architecture decisions, stamps, environment strategy, networking, phased deployment
- [Infrastructure Technical Design](Infrastructure-Technical-Design) — VNet/subnet layout, NAT gateway, traffic flow, NSG rule sets
- [Azure Infrastructure Bill of Materials](Azure-Infrastructure-Bill-of-Materials) — complete resource inventory with SKUs, naming, and phases
- [Infrastructure Implementation Planning](Infrastructure-Implementation-Planning) — Terraform module design, directory structure, workspace workflow

## Application & API Layer

- [Application Planning](Application-Planning) — Function App design, endpoints, Pydantic validation, Docker container, security
- [APIM Planning](APIM-Planning) — API Management configuration, mTLS, APIM → Function App authentication

## CI/CD

- [CI CD Approach](CI-CD-Approach) — pipelines, branch-to-environment model, runner strategy, promotion flow
