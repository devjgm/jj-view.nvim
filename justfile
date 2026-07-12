# jj-view.nvim tasks. Run `just` to list them.

# show the available recipes
default:
    @just --list

# run the test suite (headless nvim, no external deps)
test:
    nvim -l tests/run.lua

# format all lua with stylua
fmt:
    stylua lua tests

# check formatting without writing (for CI / pre-push)
check:
    stylua --check lua tests

# format-check and test
all: check test
