# Udev Add Trigger Design

## Problem

The Pika sensor rules create stable device links only for `ACTION==\"add\"`. Several setup and start scripts reload the rules and then run bare `udevadm trigger`, whose default action is `change`. That event does not match the rules and removes the custom `/dev/ttyUSB50`, `/dev/ttyUSB51`, `/dev/video50`, and `/dev/video51` links from the udev database.

## Design

Every project-owned `udevadm trigger` used by Pika hardware setup must explicitly pass `--action=add`. The change applies to checked-in sensor scripts, generated script templates, setup documentation, and the deployed source/runtime copies on the KW host. Device path rules and left/right assignments remain unchanged.

## Verification

A repository regression script scans the operational script and documentation paths and fails when it finds a trigger command without `--action=add`. On the KW host, verification reloads the rules, emits add events, confirms all four stable links, and confirms no deployed runtime file retains a bare trigger command.
