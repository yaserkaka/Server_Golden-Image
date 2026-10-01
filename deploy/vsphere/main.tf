data "vsphere_datacenter" "this" {
  name = var.datacenter
}

data "vsphere_compute_cluster" "this" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.this.id
}

data "vsphere_datastore" "this" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.this.id
}

data "vsphere_network" "this" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.this.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.this.id
}

# Clones from the golden template. Per-VM identity (hostname, network, admin
# user) is handed to cloud-init through VMware guestinfo properties, which the
# image's cloud-init reads with its VMware datasource on first boot.
resource "vsphere_virtual_machine" "clone" {
  for_each = var.vms

  name             = each.key
  folder           = var.vm_folder != "" ? var.vm_folder : null
  resource_pool_id = data.vsphere_compute_cluster.this.resource_pool_id
  datastore_id     = data.vsphere_datastore.this.id

  num_cpus  = each.value.cpus
  memory    = each.value.memory_mb
  guest_id  = data.vsphere_virtual_machine.template.guest_id
  firmware  = data.vsphere_virtual_machine.template.firmware
  scsi_type = data.vsphere_virtual_machine.template.scsi_type

  network_interface {
    network_id   = data.vsphere_network.this.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "disk0"
    size             = max(each.value.disk_gb, data.vsphere_virtual_machine.template.disks[0].size)
    thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  extra_config = {
    "guestinfo.metadata" = base64encode(templatefile("${path.module}/templates/metadata.yaml.tftpl", {
      hostname    = each.key
      ip_cidr     = each.value.ip_cidr
      gateway     = var.gateway
      dns_servers = var.dns_servers
      domain      = var.domain
    }))
    "guestinfo.metadata.encoding" = "base64"
    "guestinfo.userdata" = base64encode(templatefile("${path.module}/templates/userdata.yaml.tftpl", {
      hostname       = each.key
      domain         = var.domain
      admin_user     = var.admin_user
      ssh_public_key = var.ssh_public_key
      roles          = each.value.roles
      role_env       = var.role_env
    }))
    "guestinfo.userdata.encoding" = "base64"
  }

  wait_for_guest_net_timeout = 10

  lifecycle {
    # A newer template must not force existing clones to be rebuilt
    ignore_changes = [clone[0].template_uuid]
  }
}
