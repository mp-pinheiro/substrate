#!/usr/bin/env bash
maintenance_run() {
    exec substrate-engine maintenance "$@"
}
