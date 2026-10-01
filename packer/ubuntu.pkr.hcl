locals {
  image_version = formatdate("YYYYMMDD-hhmm", timestamp())
  build_date    = formatdate("YYYY-MM-DD", timestamp())

  # Ubuntu autoinstall answer file (the Linux equivalent of unattend.xml)
  autoinstall_user_data = templatefile("${path.root}/autoinstall/user-data.pkrtpl.hcl", {
    hostname      = var.image_name
    username      = var.build_username
    password_hash = var.build_password_hash
    locale        = var.locale
    keyboard      = var.keyboard_layout
  })

  # QEMU serves the seed over Packer's built-in HTTP server
  http_seed = {
    "/user-data" = local.autoinstall_user_data
    "/meta-data" = ""
  }

  # vSphere attaches the seed as a CD labelled "cidata" (no HTTP reachability needed)
  cd_seed = {
    "user-data" = local.autoinstall_user_data
    "meta-data" = ""
  }

  # Last command of every build: delete the temporary build account, then power off.
  shutdown_command = "sudo sh -c 'userdel --force --remove ${var.build_username} || true; rm -f /etc/sudoers.d/90-${var.build_username}; shutdown -P now'"
}

# ---------------------------------------------------------------------------
# Source 1: QEMU/KVM -> qcow2 image
# ---------------------------------------------------------------------------
source "qemu" "ubuntu" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  vm_name            = "${var.image_name}.qcow2"
  output_directory   = "${path.root}/../output/qemu"
  format             = "qcow2"
  disk_size          = "${var.disk_size_gb}G"
  disk_interface     = "virtio"
  disk_discard       = "unmap"
  disk_detect_zeroes = "unmap"
  disk_compression   = true
  net_device         = "virtio-net"
  accelerator        = var.qemu_accelerator
  cpus               = var.cpus
  memory             = var.memory_mb
  headless           = var.headless

  http_content = local.http_seed
  boot_wait    = var.boot_wait
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=\"nocloud;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/\"<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.build_username
  ssh_password           = var.build_password
  ssh_timeout            = "60m"
  ssh_handshake_attempts = 100

  shutdown_command = local.shutdown_command
  shutdown_timeout = "15m"
}

# ---------------------------------------------------------------------------
# Source 2: VMware vSphere -> VM template
# ---------------------------------------------------------------------------
source "vsphere-iso" "ubuntu" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_username
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection
  datacenter          = var.vsphere_datacenter
  cluster             = var.vsphere_cluster
  datastore           = var.vsphere_datastore
  folder              = var.vsphere_folder

  vm_name              = "${var.image_name}-${local.image_version}"
  guest_os_type        = "ubuntu64Guest"
  firmware             = "efi"
  CPUs                 = var.cpus
  RAM                  = var.memory_mb
  disk_controller_type = ["pvscsi"]

  storage {
    disk_size             = var.disk_size_gb * 1024
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum
  cd_content   = local.cd_seed
  cd_label     = "cidata"
  remove_cdrom = true

  boot_order = "disk,cdrom"
  boot_wait  = var.boot_wait
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  ip_wait_timeout = "60m"
  communicator    = "ssh"
  ssh_username    = var.build_username
  ssh_password    = var.build_password
  ssh_timeout     = "60m"

  shutdown_command = local.shutdown_command
  shutdown_timeout = "15m"

  convert_to_template = true
  notes               = "Ubuntu ${var.ubuntu_version} golden image ${local.image_version}. Built by Packer on ${local.build_date}."
}

# ---------------------------------------------------------------------------
# Build: install -> configure -> generalize ("sysprep") -> shut down
# ---------------------------------------------------------------------------
build {
  name    = "ubuntu-golden"
  sources = ["source.qemu.ubuntu", "source.vsphere-iso.ubuntu"]

  # 1. Wait for first boot to settle (cloud-init, background apt jobs)
  provisioner "shell" {
    script          = "${path.root}/../scripts/prepare.sh"
    execute_command = "sudo env {{ .Vars }} bash '{{ .Path }}'"
  }

  # 2. Upload config files used by the provisioning scripts -> /tmp/files
  provisioner "file" {
    source      = "${path.root}/../files"
    destination = "/tmp"
  }

  # 3. Configure the image: baseline, hardening, tuning, monitoring, first-boot units
  provisioner "shell" {
    execute_command = "sudo env {{ .Vars }} bash '{{ .Path }}'"
    environment_vars = [
      "IMAGE_NAME=${var.image_name}",
      "IMAGE_VERSION=${local.image_version}",
      "UBUNTU_VERSION=${var.ubuntu_version}",
      "BUILD_HYPERVISOR=${source.type}",
      "FILES_DIR=/tmp/files",
    ]
    scripts = [
      "${path.root}/../scripts/provision/10-common.sh",
      "${path.root}/../scripts/provision/20-hardening.sh",
      "${path.root}/../scripts/provision/30-tuning.sh",
      "${path.root}/../scripts/provision/40-node-exporter.sh",
      "${path.root}/../scripts/provision/50-firstboot.sh",
      "${path.root}/../scripts/provision/60-roles.sh",
    ]
  }

  # 4. Generalize: strip machine identity so every clone boots as a new machine
  provisioner "shell" {
    script          = "${path.root}/../scripts/generalize.sh"
    execute_command = "sudo env {{ .Vars }} bash '{{ .Path }}'"
  }

  post-processor "manifest" {
    output     = "${path.root}/../output/manifest.json"
    strip_path = true
    custom_data = {
      image_name     = var.image_name
      image_version  = local.image_version
      ubuntu_version = var.ubuntu_version
    }
  }

  post-processor "checksum" {
    only           = ["qemu.ubuntu"]
    checksum_types = ["sha256"]
    output         = "${path.root}/../output/qemu/${var.image_name}.{{ .ChecksumType }}"
  }
}
