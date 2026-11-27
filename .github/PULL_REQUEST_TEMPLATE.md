## Summary
<!-- Describe what this PR changes and why. -->

## Type of Change
- [ ] Bug fix
- [ ] Driver / hardware support
- [ ] Kernel subsystem / security / memory
- [ ] Build / CI / test infrastructure
- [ ] Documentation

## Verification
- [ ] `UPDATE_RUNTIME_DISK=1 ./build.sh` completes with zero warnings/errors
- [ ] `./tests/qemu_smoke_test.sh` passes all boot milestones
- [ ] Tested interactively with `./run-arkm-uefi-only-qemu.sh` (if UI/HID/networking changed)
- [ ] No generated binaries, disk images, or `.log` files committed
