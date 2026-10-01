PACKER        ?= packer
TERRAFORM     ?= terraform
PACKER_DIR    := packer
VSPHERE_VARS  ?= $(PACKER_DIR)/vsphere.pkrvars.hcl
IMAGE         ?= output/qemu/ubuntu-2404-golden.qcow2
SHELL_SCRIPTS := $(wildcard scripts/*.sh scripts/provision/*.sh deploy/kvm/*.sh files/sbin/*.sh files/roles/*.sh)

.DEFAULT_GOAL := help
.PHONY: help init validate lint build-qemu build-vsphere inspect deploy-kvm render-kvm \
        destroy-kvm verify tf-init tf-plan tf-apply tf-destroy clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- Build -------------------------------------------------------------------
init: ## Install Packer plugins
	$(PACKER) init $(PACKER_DIR)

validate: init ## Check Packer formatting and configuration
	$(PACKER) fmt -check -recursive $(PACKER_DIR)
	$(PACKER) validate -syntax-only $(PACKER_DIR)

lint: ## Lint shell scripts and Terraform
	shellcheck $(SHELL_SCRIPTS)
	$(TERRAFORM) fmt -check -recursive deploy/vsphere

build-qemu: init ## Build the qcow2 golden image with QEMU/KVM
	$(PACKER) build -force -only='ubuntu-golden.qemu.ubuntu' $(PACKER_DIR)

build-vsphere: init ## Build the vSphere template (needs packer/vsphere.pkrvars.hcl + PKR_VAR_vsphere_password)
	$(PACKER) build -only='ubuntu-golden.vsphere-iso.ubuntu' -var-file=$(VSPHERE_VARS) $(PACKER_DIR)

inspect: ## Offline check that the qcow2 image is generalized (needs libguestfs-tools)
	./scripts/inspect-image.sh $(IMAGE)

# --- Deploy: KVM -------------------------------------------------------------
render-kvm: ## Render the clones' cloud-init files without creating VMs
	DRY_RUN=1 ./deploy/kvm/deploy.sh

deploy-kvm: ## Clone the VMs listed in deploy/kvm/hosts.csv
	sudo IMAGE=$(abspath $(IMAGE)) ./deploy/kvm/deploy.sh

destroy-kvm: ## Remove the KVM clones
	sudo ./deploy/kvm/destroy.sh

verify: ## Check clones are unique and healthy (machine-id, host keys, services)
	./scripts/verify-clones.sh

# --- Deploy: vSphere ---------------------------------------------------------
tf-init: ## terraform init for vSphere clones
	$(TERRAFORM) -chdir=deploy/vsphere init

tf-plan: ## terraform plan for vSphere clones
	$(TERRAFORM) -chdir=deploy/vsphere plan

tf-apply: ## Create vSphere clones from the template
	$(TERRAFORM) -chdir=deploy/vsphere apply

tf-destroy: ## Remove vSphere clones
	$(TERRAFORM) -chdir=deploy/vsphere destroy

clean: ## Remove build output and rendered files
	rm -rf output packer_cache deploy/kvm/.render
