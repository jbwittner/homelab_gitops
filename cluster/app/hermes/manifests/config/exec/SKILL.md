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

There are two modes. **Pick the right one before you start** — switching later means losing
whatever you built.

### One-shot — a single self-contained command

```
hermes-exec-run <task-id> '<shell command>' [--image busybox|python] [--ttl N] [--deadline N] [--keep]
hermes-exec-run --list
```

Blocks until the task finishes, prints its logs, deletes it. Each call is a **fresh pod with an
empty `/work`**. Nothing carries over between two calls.

### Session — several commands that build on each other

Use this whenever the work has more than one step: write a file then run it, run a test then fix
and re-run, inspect output then act on it.

```
hermes-exec-run session start <id> [--image busybox|python] [--deadline N]
hermes-exec-run session run   <id> '<shell command>'
hermes-exec-run session stop  <id>
hermes-exec-run session list
```

The pod stays alive between `run` calls and `/work` keeps its contents. Exit codes are returned,
stdout and stderr are separated.

```
hermes-exec-run session start build
hermes-exec-run session run build 'cat > /work/app.py <<EOF
print(sum(range(10)))
EOF'
hermes-exec-run session run build 'python3 /work/app.py'
hermes-exec-run session stop build
```

**Always `session stop` when done.** A session pod never finishes on its own, so the normal TTL
cleanup does not apply to it — only its `--deadline` (1 hour by default) will eventually kill it.
Until then it holds one of the two available slots.

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
- **At most two pods at a time**, sessions included. A third is refused with `exceeded quota`.
  A forgotten session holds a slot for a full hour — `hermes-exec-run session list` shows them,
  `session stop` frees them.

## Do Not Try To Work Around This

You have no permission to create pods any other way, and no permission to change the quota, the
network policies, or the roles. If a task needs something the sandbox does not provide, say so to
the user and explain what is missing. Do not attempt to run the work in your own container as a
substitute — that container is not isolated, and it is the thing the sandbox exists to protect.
