# The provider version is PINNED. It must equal K8S_PROVIDER_VERSION in
# scripts/versions.env; checks/01-pins.sh verifies that.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.38.0"
    }
  }

  # Shared backend: one backend/workspace identity, in a namespace SEPARATE
  # from the target object's. TC-03's lineage/serial rejection is tested here.
  # config_path is NOT written here. With a fixed "~/.kube/config" the
  # experiment depended on whichever cluster the user's GLOBAL kubeconfig
  # pointed at, a dependency nothing recorded. The run's own kubeconfig is
  # passed with -backend-config (scripts/lib.sh tofu_prepare).
  backend "kubernetes" {
    secret_suffix = "t27"
    namespace     = "t27-state"
  }
}

provider "kubernetes" {
  # The run's kubeconfig is passed with TF_VAR_kubeconfig.
  config_path = var.kubeconfig
}
