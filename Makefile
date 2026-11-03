# omerfsen.nico. Run `make help` for targets.
SHELL := /bin/bash
VENV := .venv
BIN := $(VENV)/bin
PYTHON ?= python3

.PHONY: help dev lint kvm cluster kvm-destroy build

help:
	@echo "  make dev           venv + dependencies + this repo linked as omerfsen.nico"
	@echo "                     (on the build machine: make dev PYTHON=/home/linuxbrew/.linuxbrew/opt/python@3.12/bin/python3.12)"
	@echo "  make lint          ansible-lint (production profile) and playbook syntax"
	@echo "  make kvm           the whole lab on KVM: networks, then the NICo site cluster"
	@echo "  make cluster       only the NICo site cluster (VMs + kubeadm + Calico)"
	@echo "  make kvm-destroy   destroy the lab VMs (asks for confirmation)"
	@echo "  make build         build the collection tarball for Galaxy"

$(BIN)/ansible-playbook:
	$(PYTHON) -m venv $(VENV)
	$(BIN)/pip install -q -r requirements.txt

dev: $(BIN)/ansible-playbook
	$(BIN)/ansible-galaxy collection install -r requirements.yml -p .collections
	mkdir -p .collections/ansible_collections/omerfsen
	ln -sfn ../../.. .collections/ansible_collections/omerfsen/nico

lint: dev
	$(BIN)/ansible-lint --profile production
	$(BIN)/ansible-playbook --syntax-check playbooks/*.yml

kvm: dev
	$(BIN)/ansible-playbook playbooks/kvm.yml

cluster: dev
	$(BIN)/ansible-playbook playbooks/cluster.yml

kvm-destroy: dev
	@read -r -p "Destroy every NICo lab VM in inventory/kvm? Type yes: " answer; \
	  $(BIN)/ansible-playbook playbooks/kvm_destroy.yml -e nico_kvm_destroy_confirm=$$answer

build: dev
	$(BIN)/ansible-galaxy collection build --force
