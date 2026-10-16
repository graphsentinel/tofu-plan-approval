# One experiment object: ConfigMap t27/t27, measured field data.value.
# Chosen for simplicity: no CRD, webhook, operator or finalizer noise. If the
# conflict appears on the plainest resource, it appears on richer ones too.

variable "value" {
  description = "data.value: A start, B approved, C second writer"
  type        = string
  default     = "A"
}

# No default on purpose: without it tofu asks or fails. Silently falling back
# to the global kubeconfig left it unclear which cluster the experiment wrote to.
variable "kubeconfig" {
  description = "The run's kubeconfig path, passed with TF_VAR_kubeconfig"
  type        = string
}

# TC-03 lock precondition. When set, the create step waits until it can read
# this local FIFO; for that whole time the apply HOLDS the state lock. The
# second runner tries at that moment with -lock-timeout=1s.
variable "lock_fifo" {
  description = "When set, create waits until this FIFO has been read"
  type        = string
  default     = ""
}

# TC-06 only: a plan that changes labels, and a plan that also creates a second object. With the defaults the
# configuration is the one TC-01 to TC-05 use (labels = null is the same as no labels argument).
variable "labels" {
  description = "metadata.labels of the experiment object (TC-06)"
  type        = map(string)
  default     = {}
}

variable "extra" {
  description = "also manage a second ConfigMap, t27/t27-extra (TC-06)"
  type        = bool
  default     = false
}

resource "kubernetes_config_map" "t27" {
  metadata {
    name      = "t27"
    namespace = "t27"
    labels    = length(var.labels) > 0 ? var.labels : null
  }

  data = {
    value = var.value
  }

  provisioner "local-exec" {
    when    = create
    command = var.lock_fifo == "" ? "true" : "cat ${var.lock_fifo} > /dev/null"
  }
}

resource "kubernetes_config_map" "extra" {
  count = var.extra ? 1 : 0
  metadata {
    name      = "t27-extra"
    namespace = "t27"
  }
  data = {
    value = "extra"
  }
}

output "value" { value = kubernetes_config_map.t27.data["value"] }
