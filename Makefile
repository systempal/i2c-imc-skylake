obj-m := i2c-imc-skylake.o

KVER   ?= $(shell uname -r)
KDIR   ?= /lib/modules/$(KVER)/build
INSTALL_MOD_PATH ?= $(DESTDIR)
INSTALL_MOD_DIR  ?= updates
PWD    := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

# Install through Kbuild so ownership, compression and destination follow the
# target kernel/distribution policy. Invoke this target with suitable privileges.
install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install \
		INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) \
		INSTALL_MOD_DIR=$(INSTALL_MOD_DIR)

# Remove a module installed in INSTALL_MOD_DIR. Invoke with suitable privileges.
uninstall:
	rm -f $(INSTALL_MOD_PATH)/lib/modules/$(KVER)/$(INSTALL_MOD_DIR)/i2c-imc-skylake.ko*
	depmod -a -b $(INSTALL_MOD_PATH) $(KVER)

# Runtime helpers require explicit acknowledgement of the firmware-arbitration
# risk: make reload ALLOW_UNSAFE=1 (or make load ALLOW_UNSAFE=1).
reload: all
	@test "$(ALLOW_UNSAFE)" = "1" || \
		{ echo "Refusing: rerun with ALLOW_UNSAFE=1" >&2; exit 2; }
	sudo rmmod i2c-imc-skylake 2>/dev/null || true
	sudo insmod i2c-imc-skylake.ko allow_unsafe_access=1

# Load without build (use after install)
load:
	@test "$(ALLOW_UNSAFE)" = "1" || \
		{ echo "Refusing: rerun with ALLOW_UNSAFE=1" >&2; exit 2; }
	sudo modprobe i2c-dev
	sudo modprobe i2c-imc-skylake allow_unsafe_access=1

unload:
	sudo rmmod i2c-imc-skylake 2>/dev/null || true

# Checkpatch (must be clean before submission)
checkpatch:
	perl $(KDIR)/scripts/checkpatch.pl --strict --no-tree -f i2c-imc-skylake.c

# Sparse static analysis (requires sparse >= kernel version; may show header errors on old sparse)
sparse:
	$(MAKE) -C $(KDIR) M=$(PWD) C=1 CF="-D__CHECK_ENDIAN__"

# Smoke test requires root or non-interactive sudo.
test: all
	MODULE_PATH=$(PWD)/i2c-imc-skylake.ko bash test-smoke.sh

# Hardware measurements that the upstream submission still needs. Read-only
# unless explicitly asked otherwise; see tools/README.md.
measure:
	@echo "Run the scripts under tools/ individually; see tools/README.md" >&2
	@false

log:
	sudo dmesg | grep i2c-imc-skylake | tail -80

.PHONY: all clean install uninstall reload load unload checkpatch sparse test measure log
