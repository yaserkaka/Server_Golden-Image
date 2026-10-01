#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.${DOMAIN}
users:
  - name: ${ADMIN_USER}
    gecos: Operations admin
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUBKEY}
package_update: false
final_message: "Clone ${VM_NAME} is ready (cloud-init finished after $UPTIME seconds)"
${ROLES_BLOCK}
