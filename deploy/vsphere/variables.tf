# --- vCenter connection -------------------------------------------------------
variable "vsphere_server" {
  type = string
}

variable "vsphere_username" {
  type = string
}

variable "vsphere_password" {
  type        = string
  sensitive   = true
  description = "Prefer the TF_VAR_vsphere_password environment variable."
}

variable "vsphere_insecure" {
  type    = bool
  default = false
}

# --- Placement ----------------------------------------------------------------
variable "datacenter" {
  type = string
}

variable "cluster" {
  type = string
}

variable "datastore" {
  type = string
}

variable "network" {
  type = string
}

variable "vm_folder" {
  type    = string
  default = ""
}

variable "template_name" {
  type        = string
  description = "Template created by Packer, e.g. ubuntu-2404-golden-20261001-1200 (see output/manifest.json)."
}

# --- Guest configuration ------------------------------------------------------
variable "domain" {
  type    = string
  default = "lab.local"
}

variable "gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "admin_user" {
  type    = string
  default = "ops"
}

variable "ssh_public_key" {
  type        = string
  description = "Public key installed for admin_user."
}

variable "vms" {
  description = "Clones to create, keyed by hostname. ip_cidr may be \"dhcp\". roles are applied on first boot."
  type = map(object({
    ip_cidr   = string
    cpus      = number
    memory_mb = number
    disk_gb   = number
    roles     = optional(list(string), [])
  }))

  validation {
    condition = alltrue(flatten([
      for vm in values(var.vms) : [
        for role in vm.roles : contains(["docker", "hpc-bench", "hpc-compute", "k8s-node", "nfs-server", "web"], role)
      ]
    ]))
    error_message = "Unknown role. Available roles: docker, hpc-bench, hpc-compute, k8s-node, nfs-server, web."
  }
}

variable "role_env" {
  description = "Settings handed to every clone's roles (written to /etc/golden-image/role.env)."
  type        = map(string)
  default     = {}
}
