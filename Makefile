obj-m := i2c-imc-skylake.o

KVER   ?= $(shell uname -r)
KDIR   ?= /lib/modules/$(KVER)/build
MODDIR  = /lib/modules/$(KVER)/kernel/drivers/i2c/busses
PWD    := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

# Install into kernel tree + modprobe.
# Ubuntu/Debian kernel 6.x+ ships .ko.zst; depmod skips uncompressed .ko files,
# so compress with zstd when available, else fall back to plain .ko.
install: all
	if command -v zstd >/dev/null 2>&1; then \
		zstd -q -f i2c-imc-skylake.ko -o i2c-imc-skylake.ko.zst; \
		sudo install -D -m 644 i2c-imc-skylake.ko.zst $(MODDIR)/i2c-imc-skylake.ko.zst; \
		sudo rm -f $(MODDIR)/i2c-imc-skylake.ko; \
	else \
		sudo install -D -m 644 i2c-imc-skylake.ko $(MODDIR)/i2c-imc-skylake.ko; \
		sudo rm -f $(MODDIR)/i2c-imc-skylake.ko.zst; \
	fi
	sudo depmod -a $(KVER)
	sudo modprobe i2c-imc-skylake

# Remove module and .ko/.ko.zst from kernel tree
uninstall:
	sudo rmmod i2c-imc-skylake 2>/dev/null || true
	sudo rm -f $(MODDIR)/i2c-imc-skylake.ko $(MODDIR)/i2c-imc-skylake.ko.zst
	sudo depmod -a $(KVER)

# Quick rmmod + insmod cycle for leak/oops testing
reload: all
	sudo rmmod i2c-imc-skylake 2>/dev/null || true
	sudo insmod i2c-imc-skylake.ko

# Load without build (use after install)
load:
	sudo modprobe i2c-dev
	sudo modprobe i2c-imc-skylake

unload:
	sudo rmmod i2c-imc-skylake 2>/dev/null || true

# Checkpatch (must be clean before submission)
checkpatch:
	perl $(KDIR)/scripts/checkpatch.pl --strict --no-tree -f i2c-imc-skylake.c

# Sparse static analysis (requires sparse >= kernel version; may show header errors on old sparse)
sparse:
	$(MAKE) -C $(KDIR) M=$(PWD) C=1 CF="-D__CHECK_ENDIAN__"

# Smoke test — requires root + module loaded (run after make install or make reload)
test:
	sudo bash test-smoke.sh

log:
	sudo dmesg | grep i2c-imc-skylake | tail -80

.PHONY: all clean install uninstall reload load unload checkpatch sparse test log
