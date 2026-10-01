#cloud-config
# Ubuntu Server autoinstall (Subiquity) - unattended OS install used by Packer.
# Rendered by Packer's templatefile(); $${...} values are filled in at build time.
autoinstall:
  version: 1
  locale: ${locale}
  keyboard:
    layout: ${keyboard}
  source:
    id: ubuntu-server-minimal
  network:
    version: 2
    ethernets:
      primary:
        match:
          name: "e*"
        dhcp4: true
  storage:
    layout:
      name: lvm
      sizing-policy: all
  identity:
    hostname: ${hostname}
    username: ${username}
    password: "${password_hash}"
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - cloud-init
    - cloud-guest-utils
    - open-vm-tools
    - qemu-guest-agent
    - python3
    - sudo
  updates: security
  late-commands:
    # Passwordless sudo for the temporary build user (removed at the end of the build)
    - echo '${username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-${username}
    - chmod 0440 /target/etc/sudoers.d/90-${username}
  shutdown: reboot
