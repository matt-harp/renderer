#!/usr/bin/env bash

export MESA_VK_IGNORE_CONFORMANCE_WARNING=true
odin run src -debug -vet -out:build/engine
