# ─────────────────────────────────────────────────────────────────────────────
# dev.tfvars — dev workspace overrides for phase1/env
#
# Usage:
#   terraform -chdir=terraform/phase1/env workspace select dev
#   terraform -chdir=terraform/phase1/env apply \
#     -var-file=terraform.tfvars -var-file=dev.tfvars
#
# Stamp names here must have matching subnet pairs in phase1/core:
#   snet-stamp-dev-<stamp_name>-pe / snet-stamp-dev-<stamp_name>-asp
# ─────────────────────────────────────────────────────────────────────────────

stamps = [
  {
    stamp_name = "1"
    location   = "northeurope"
    image_name = "wkld-api"
    image_tag  = "dev"
  },
  {
    stamp_name = "2"
    location   = "northeurope"
    image_name = "wkld-api"
    image_tag  = "dev"
  },
]
