# Development Approach

## Methodology

I will begin by standing up the required infrastructure and then implement required software and configuration. My activites will be:
Infra Documentation Design -> Infra Stand-Up -> Software Development -> Testing & Validation

I will focus on ensuring that there is a complete and well-documented Infra Design, which will allow me to make effective use of AI to implement the design. As a platform engineer, I can add value most by focusing on design, tradeoff and architecture, rather than specific Terraform syntax or formatting, which AI can assist with.

This approach has several benefits:
- I am able to focus time on value-adding activities rather than getting bogged down in formatting and layout
- I retain full control over the design and implementation decisions, and can ensure that the solution is fully aligned to my intent
- The documentation provides a record of my thinking, and avoids the contextual gap that a prompt-by-prompt approach can create, where a future developer may not understand why certain decisions were made or the rationale behind them, only having the final code. 

## Deferred Activities

Hub/Spoke - Ideally, I would like a seperate network hub to the workload-shared infrastructure, but this adds more complexity and brings routing/peering into the mix, which is not the focus of this assessment. For now, the shared infra and the workload stamps will live in the same VNet, but in a real-world scenario I would likely separate these concerns.