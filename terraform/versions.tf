terraform {
  required_version = ">= 1.3"

  required_providers {
    aiven = {
      source  = "aiven/aiven"
      version = ">= 4.0.0, < 5.0.0"
    }
  }
}

# Authentication: export AIVEN_TOKEN=<your token> (demo3_aiven.sh --terraform does
# this for you from AIVEN_AUTH_TOKEN or your `avn user login` credentials),
# or set the aiven_api_token variable.
provider "aiven" {
  api_token = var.aiven_api_token
}
