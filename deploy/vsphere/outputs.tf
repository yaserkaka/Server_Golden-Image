output "clones" {
  description = "Hostname => IP address reported by VMware Tools"
  value       = { for name, vm in vsphere_virtual_machine.clone : name => vm.default_ip_address }
}
