packer {
  required_version = ">= 1.10.0"

  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
    vsphere = {
      source  = "github.com/hashicorp/vsphere"
      version = ">= 1.4.0"
    }
  }
}
