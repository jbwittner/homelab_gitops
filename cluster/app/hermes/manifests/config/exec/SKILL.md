---
name: disposable-exec
description: Run untrusted or experimental code in a disposable, network-isolated Kubernetes pod instead of in your own container. Use for building, testing, running generated code, or anything you would not want to leave behind.
version: 1.0.0
author: homelab-gitops
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [kubernetes, sandbox, isolation, execution]
    category: devops
    requires_toolsets: [terminal]
---

# Disposable Execution Environments

Run a command in a throwaway pod that is destroyed afterwards, instead of running it in your own
container.

## When to Use

Use this whenever you would otherwise run something in your own shell that is:

- code you generated and have not verified;
- a build, a test suite, or a script from a repository;
- anything that writes files you do not want to keep;
- anything you would rather not have running next to your own process.

Do **not** use it for reading your own configuration, inspecting your own state, or short shell
one-liners that only touch your own workspace. Those belong in your own terminal.

## How to Run

```
hermes-exec-run <task-id> '<shell command>' [--image busybox|python] [--ttl N] [--deadline N] [--keep]
hermes-exec-run --list
```

The command blocks until the task finishes, then prints its logs and deletes it.

- `task-id` — lowercase letters, digits and `-`, 40 characters max. Pick something that names the
  task, not a random string; it appears in the pod name and in the logs.
- `--image` — `busybox` (default) or `python`. Nothing else is accepted.
- `--ttl` — seconds the finished task is kept before automatic deletion. Default 300.
- `--deadline` — hard wall-clock limit. The pod is killed past it, running or not. Default 900.
- `--keep` — do not delete on completion; the TTL still applies.

Example:

```
hermes-exec-run sort-check 'printf "b\na\n" > /work/in.txt; sort /work/in.txt'
```

## What the Environment Gives You

- A writable `/work` directory, and `/tmp`. **Everything else is read-only.**
- User id 65532. You are not root and cannot become root.
- 1 CPU, 1 GiB memory, 2 GiB of disk, at most.

## What the Environment Does Not Give You

Read this before writing the command, because these failures look like bugs and are not:

- **No network at all.** Not the internet, not the local network, **not even DNS**. Every
  `pip install`, `npm install`, `apt-get`, `git clone` or `curl` will fail. This is the point of
  the sandbox, not a misconfiguration. Whatever the task needs must already be in the image.
- **No credentials.** No Kubernetes token, no SSH key, no registry login. Nothing to authenticate
  with, and nothing to leak.
- **No persistence.** `/work` is destroyed with the pod. If a result matters, print it to stdout —
  the logs come back to you.
- **At most two tasks at a time.** A third is refused with `exceeded quota`. Wait, or use
  `hermes-exec-run --list` and let the running ones finish.

## Do Not Try To Work Around This

You have no permission to create pods any other way, and no permission to change the quota, the
network policies, or the roles. If a task needs something the sandbox does not provide, say so to
the user and explain what is missing. Do not attempt to run the work in your own container as a
substitute — that container is not isolated, and it is the thing the sandbox exists to protect.
