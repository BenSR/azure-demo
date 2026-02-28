# ─────────────────────────────────────────────────────────────────────────────
# prod.tfvars — prod workspace overrides for phase1/env
#
# Usage:
#   terraform -chdir=terraform/phase1/env workspace select prod
#   terraform -chdir=terraform/phase1/env apply \
#     -var-file=terraform.tfvars -var-file=prod.tfvars
#
# Stamp names here must have matching subnet pairs in phase1/core:
#   snet-stamp-prod-<stamp_name>-pe / snet-stamp-prod-<stamp_name>-asp
# ─────────────────────────────────────────────────────────────────────────────

stamps = [
  {
    stamp_name = "1"
    location   = "uksouth"
    image_name = "wkld-api"
    image_tag  = "latest"
  },
]
