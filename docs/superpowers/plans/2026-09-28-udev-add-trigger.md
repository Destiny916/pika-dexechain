# Udev Add Trigger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent Pika hardware setup scripts from removing stable udev device links.

**Architecture:** Enforce explicit add-event triggering in every checked-in operational path and deploy the same change to all source and generated runtime copies on the KW host. A static regression test protects the command contract.

**Tech Stack:** Bash, Python-generated Bash, udev, Git

---

### Task 1: Add regression coverage

**Files:**
- Create: `pika-migrate/tests/test_udev_trigger_action.sh`

- [ ] Add a scanner that rejects `udevadm trigger` lines without `--action=add`.
- [ ] Run the scanner and confirm it fails on the current bare trigger commands.

### Task 2: Repair checked-in commands

**Files:**
- Modify: `pika/pika_ros/src/sensor_tools/scripts/*.bash`
- Modify: `pika/pika_ros/src/sensor_tools/scripts/setup_device.py`
- Modify: `pika/pika_ros/src/sensor_tools/README.md`
- Modify: `pika-migrate/documents/*.md`

- [ ] Add `--action=add` to every project-owned trigger command.
- [ ] Run the regression scanner and shell/Python syntax checks.

### Task 3: Deploy and verify on the KW host

**Files:**
- Modify: `/home/kw/app/pika/pika_ros/src/sensor_tools/scripts/*`
- Modify: `/home/kw/app/pika/pika_ros/scripts/*`
- Modify: `/home/kw/app/pika/pika_ros/install/sensor_tools/share/sensor_tools/scripts/*`

- [ ] Synchronize the corrected source files and patch generated runtime copies.
- [ ] Reload udev rules and explicitly emit add events.
- [ ] Verify the four stable links and scan deployed files for bare trigger commands.

### Task 4: Record the repair

- [ ] Review the diff and verification output.
- [ ] Commit and push the permanent fix to the configured remotes.
