# ---------------------------------------------------------------------------
# Image
# ---------------------------------------------------------------------------
variable "image_name" {
  type        = string
  default     = "ubuntu-2404-golden"
  description = "Base name of the image / template."
}

variable "ubuntu_version" {
  type        = string
  default     = "24.04.5"
  description = "Ubuntu point release, recorded in the image metadata."
}

variable "iso_url" {
  type        = string
  default     = "https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso"
  description = "Ubuntu live-server ISO. When a newer point release ships, older ISOs move to old-releases.ubuntu.com."
}

variable "iso_checksum" {
  type        = string
  default     = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
  description = "ISO checksum, or a file: URL to the SHA256SUMS list."
}

# ---------------------------------------------------------------------------
# VM hardware used during the build
# ---------------------------------------------------------------------------
variable "cpus" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type    = number
  default = 4096
}

variable "disk_size_gb" {
  type        = number
  default     = 20
  description = "Template disk size. Clones can be bigger; the root LV grows on first boot."
}

variable "boot_wait" {
  type        = string
  default     = "5s"
  description = "Time to wait for the GRUB menu before typing the boot command."
}

# ---------------------------------------------------------------------------
# Temporary build account (deleted at the end of the build)
# ---------------------------------------------------------------------------
variable "build_username" {
  type    = string
  default = "packer"
}

variable "build_password" {
  type      = string
  default   = "packer"
  sensitive = true
}

variable "build_password_hash" {
  type        = string
  default     = "$6$goldenimg$Vmc5e7IBfj6kTum3SSfClz0elUvhoFC8jpK1B8.PP0w9ZkqiDeB4R/R06jSjTPJpE5s.N6ebIoJHgC3z1br2Q."
  sensitive   = true
  description = "SHA-512 crypt hash of build_password. Generate with: openssl passwd -6 '<password>'"
}

# ---------------------------------------------------------------------------
# OS defaults
# ---------------------------------------------------------------------------
variable "locale" {
  type    = string
  default = "en_US.UTF-8"
}

variable "keyboard_layout" {
  type    = string
  default = "us"
}

# ---------------------------------------------------------------------------
# QEMU / KVM builder
# ---------------------------------------------------------------------------
variable "qemu_accelerator" {
  type        = string
  default     = "kvm"
  description = "Use 'tcg' when /dev/kvm is not available (much slower)."
}

variable "headless" {
  type    = bool
  default = true
}

# ---------------------------------------------------------------------------
# VMware vSphere builder (only needed for the vsphere-iso build)
# ---------------------------------------------------------------------------
variable "vsphere_server" {
  type    = string
  default = ""
}

variable "vsphere_username" {
  type    = string
  default = ""
}

variable "vsphere_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Prefer the PKR_VAR_vsphere_password environment variable over a file."
}

variable "vsphere_insecure_connection" {
  type    = bool
  default = false
}

variable "vsphere_datacenter" {
  type    = string
  default = ""
}

variable "vsphere_cluster" {
  type    = string
  default = ""
}

variable "vsphere_datastore" {
  type    = string
  default = ""
}

variable "vsphere_network" {
  type    = string
  default = ""
}

variable "vsphere_folder" {
  type    = string
  default = "Templates"
}
