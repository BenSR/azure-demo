# Developer Log

---

### 1 — Requirements Refinement
**Tool:** GitHub Copilot Chat (Claude 4.6 Opus)

**Goal:** Extract requirements from the specification file and separate them from constraints and assumptions. Store the requirements in a new file called "1_requirements.md" and

**Prompt:**
> "Please extract all relevant functional and nonfunctional requirements from this specification file and store them in a directory called "docs". Incorporate all stretch goals in the spec file in your requirements."

**Comments:** Structure looks OK, but the wording of the requirements needs some improvement. Some of the requirements read as instructions or constraints, not true requirements. This is more of a transposition than a refinement.

---

### 2 — Supporting Infra Incorporation
**Tool:** GitHub Copilot Chat (Claude 4.6 Opus)

**Goal:* Make the requirements more actionable and less like instructions. Separate out the constraints and assumptions into a new file .

**Prompt:**
> "I think we have some entagling of requirements (what the system shall do) and constraints / assumptions. Let's make sure the requirements follow best practice in requirement naming (e.g the system shall....) and create a seperate file for constraints / assumptions"

**Comments:** Worked well, everything is now nicely seperated. Will now proceed to add my own design intent and solution design decisions as another file.

---

### 3 — Capturing Author Design Intent & Framing
**Tool:** Non-AI

To capture my design intent for this problem, I will now write documentation that explains the principles I want to follow and the design choices I make. This will be my solution_design.md file.

---

### 4 — Author Design Intent Tidy-Up
**Tool:** GitHub Copilot Chat (Claude 4.6 Opus)

**Goal:* Tidy up the design intent document, improve formatting, spelling, grammar etc.

**Prompt:**
> "Can you tidy up these notes, general formatting pass, spelling, grammar, etc"

**Comments:** Doc is now readable.

### 4 - Workspace Setup
**Tool:** GitHub Copilot Chat (Claude 4.6 Opus)

**Goal** Start to get the dev environment ready, make sure that everything is where we expect. 

**Prompt:**
> "Can you get this vscode workspace fully configured please, devcontainer, workspace file. Devcontainer needs the azure CLI and terreaform, use devcontainer features for this. Devcontainer also needs to support python - 3.11 please. Can we also get a gitignoe in with some sensible defaults

**Comments** Just to crunch through the heavy lifting of the dev env setup. Saves me doing it by hand. 

### 5 - Implementation Planning
**Tool:** GitHub Copilot Chat (Claude 4.6 Opus)

**Goal** Plan out the terraform module structure, which resources go in which modules, what variables they take, etc. This will need careful review after generation. 

**Prompt:** Can you look at the documentation files in the docs directory and plan out, in a file named 2_module_implementation_planning.md, what terraform modules need to be created. The goal is pragmatic modularization only where it adds value. For a resource that is only ever going to exist once, for example the acr, do not use a module. The workload stamp, however, is a good candidate for modularization because a future requirement may be to support multiple instances between regions or multiple environments (dev/test/prod/dr etc). For private DNS, use a module which automatically creates the "common" private dns zones required and then exports the zone IDs as named attributes to make it simple to reference the zone ID in the private endpoint of the other resources.

Modules should default to, where it is possible, enabling managed identity, disabling private access etc.

**Comments** Looks fine, module layout looks OK and I agree with most of it. I need to define some naming conventions though, which I will do via another prompt to add a structure that makes sense for me. The key thing is that the workload stamps are numbered, and the shared workload infra is identified as shared. 

**Prompt:** Resource naming - to be done in the form of <resource type abbreviation>-<workload name>-<stamp number>-<environment> for stamp resources. So for example, the key vault for the first workload stamp in the dev environment would be kv-wkld-1-dev. For storage accounts, just remove the hyphens. I am making a design choice that *there are propbably not going to be any resource naming collisions* - as storage accounts and some other resources have global uniqueness requirements. Please add this context to the implementation planning document. For shared resources, replace the stamp number with "shared" - so for example the ACR would be acr-wkld-shared-dev. FOR THIS APP, THE WORKLOAD NAME IS wkld. 

### 6 - Connectivity Considerations

**Tool:** GitHub Copilot Chat (Claude 4.6 Opus)

**Goal** To synthesize a complete network topology based on the requirements and solution design documents. This captures the requirements for external connectivity, NSGs etc.

**Prompt:** Can you create a network topology doc, `2_network_technical_design.md`, which captures the network design for this solution. This should take into account the requirement for egress via a NAT Gateway and the requirement for a robust per-subnet NSG design. Only the GitHub-hosted runner needs egress to the internet, so the NSG rules should reflect that. The Function App should be callable only via APIM, so the NSG rules should reflect that also. The ACR needs to be reachable from both the GitHub-hosted runner and the Function App, so the NSG rules should reflect that. 

### Dev Connectivity Consideration
**Tool:** GitHub Copilot Chat (Claude 4.6 Opus)

**Goal** To ensure I can connect and debug the environment once it's deployed, I will need to have a way to connect to the VNet. I could use a VPN gateway, but this also requires a private dns resolver to be able to access the private DNS zones. I will instead opt for a windows jump box, connected to via EntraID auth and with a public IP address. Windows 11 will be fine. In the real world, I would use Bastion for this, but it is outside the scope of the assessment. The jump box will need to be in its own subnet, with NSG rules that allow RDP from the internet and outbound access to the ACR and other resources. I am not going to use a VPN gateway because it would require that I enable either a private DNS resolver or a DNS server VM to resolve the private DNS zones, which is highly complex and outside the scope of this assessment. 

**Prompt:* Please review all the documentation and introduce the self-identified design choice around using a jump box for connectivity instead of a VPN gateway. Please add this to the relevant documentation files. Ensure that the NSG rules allow the jump box to be accessed from the internet via RDP and to access the ACR and other resources in the VNet. It will be a small Windows 11 VM, with a public IP address, and will be connected to via EntraID authentication - so it will need the extension to be installed. 

### Azure Infra BoM
**Tool:** GitHub Copilot Chat (Claude 4.6 Opus)

**Goal** To define in documentation a complete list of all expected Azure resources, SKU, purpose and any other relevant details. This will be used as a reference during implementation to ensure that all required resources are created and that the design is being followed. The existence of this file will allow AI agents to use it without wasting context window on trying to infer what resources are needed.

**Prompt:** Please create a document called `2_azure_infra_bom.md` which captures a complete bill of materials for the Azure infrastructure. This should include every resource that is expected to be created, along with its SKU, purpose, and any other relevant details