version: 2
ethernets:
  primary:
    match:
      name: "en*"
    dhcp4: false
    addresses:
      - ${VM_IP_CIDR}
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      search: [${DOMAIN}]
      addresses: [${DNS_SERVERS}]
