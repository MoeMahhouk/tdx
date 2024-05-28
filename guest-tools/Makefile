.PHONY: run clean

VM_IMG ?= $(PWD)/image/tdx-guest-ubuntu-24.04-generic.qcow2
FIRMWARE ?= /usr/share/ovmf/OVMF.fd
SSH_PORT ?= 10022
PROCESS_NAME ?= td
DEVICE_ARGS ?= -device vhost-vsock-pci,guest-cid=3

check_kvm_group:
	@if ! groups | grep -qw "kvm"; then \
		echo "Please add user $$USER to kvm group to run this script (usermod -aG kvm $$USER and then log in again)."; \
		exit 1; \
	fi

run: check_kvm_group
	@qemu-system-x86_64 -D /tmp/tdx-guest-vm.log \
		-accel kvm \
		-m 2G -smp 16 \
		-name $(PROCESS_NAME),process=$(PROCESS_NAME),debug-threads=on \
		-cpu host \
		-machine q35,kernel_irqchip=split,hpet=off \
		-bios $(FIRMWARE) \
		-nographic -daemonize \
		-nodefaults \
		-device virtio-net-pci,netdev=nic0_vm -netdev user,id=nic0_vm,hostfwd=tcp::$(SSH_PORT)-:22 \
		-drive file=$(VM_IMG),if=none,id=virtio-disk0 \
		-device virtio-blk-pci,drive=virtio-disk0 \
		$(DEVICE_ARGS) \
		-pidfile /tmp/tdx-demo-td-pid.pid
	@echo "TD is running, connect with: ssh -p $(SSH_PORT) root@localhost" 

clean:
	@rm -f /tmp/tdx-guest-*.log &> /dev/null
	@rm -f /tmp/tdx-demo-*-monitor.sock &> /dev/null
	@rm -f /tmp/tdx-guest-setup.txt &> /dev/null
	@if [ -f /tmp/tdx-demo-td-pid.pid ]; then \
	    PID_TD=$(shell cat /tmp/tdx-demo-td-pid.pid 2> /dev/null); \
	    if [ ! -z "$$PID_TD" ]; then \
	        echo "Cleanup, kill TD with PID: $$PID_TD"; \
	        kill -TERM $$PID_TD &> /dev/null; \
	    fi; \
	fi
	@sleep 3
	@rm -f /tmp/tdx-demo-td-pid.pid &> /dev/null
	