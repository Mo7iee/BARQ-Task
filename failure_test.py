#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request


BASE_URL = os.getenv("BASE_URL", "http://127.0.0.1:8080")
BACKEND_TO_STOP = os.getenv("BACKEND_TO_STOP", "app-01")

REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "3"))
RECOVERY_TIMEOUT = int(os.getenv("RECOVERY_TIMEOUT", "30"))
TRAFFIC_REQUESTS = int(os.getenv("TRAFFIC_REQUESTS", "10"))


class FailureTestError(Exception):
    pass


def request(path):
    url = f"{BASE_URL}{path}"

    req = urllib.request.Request(
        url,
        method="GET",
    )

    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as response:
            body = response.read().decode("utf-8")
            return response.status, body

    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return exc.code, body

    except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
        raise FailureTestError(
            f"request to {path} failed: {exc}"
        ) from exc


def run_command(command):
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    except subprocess.CalledProcessError as exc:
        raise FailureTestError(
            f"command failed: {' '.join(command)}\n"
            f"stdout: {exc.stdout}\n"
            f"stderr: {exc.stderr}"
        ) from exc


def print_pass(message):
    print(f"PASS  {message}")


def print_fail(message):
    print(f"FAIL  {message}")


def get_instance():
    status, body = request("/instance")

    if status != 200:
        raise FailureTestError(
            f"/instance returned HTTP {status}: {body}"
        )

    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise FailureTestError(
            f"/instance returned invalid JSON: {body}"
        ) from exc

    instance = payload.get("instance_id")

    if not instance:
        raise FailureTestError(
            f"/instance response has no instance_id: {payload}"
        )

    return instance


def collect_instances(request_count):
    instances = []

    for _ in range(request_count):
        try:
            instance = get_instance()
            instances.append(instance)
        except FailureTestError:
            # A failed request is expected to be possible during
            # backend failure. Continue collecting traffic results.
            pass

    return instances


def check_initial_state():
    print("Checking initial state...")

    instances = set(collect_instances(TRAFFIC_REQUESTS))

    required = {"app-01", "app-02"}
    missing = required - instances

    if missing:
        raise FailureTestError(
            "initial traffic did not reach both backends: "
            f"observed={sorted(instances)}, "
            f"missing={sorted(missing)}"
        )

    print_pass(
        "both backends initially serve traffic: "
        f"{', '.join(sorted(instances))}"
    )


def stop_backend():
    print()
    print(f"Stopping {BACKEND_TO_STOP}...")

    run_command(
        ["docker", "compose", "stop", BACKEND_TO_STOP]
    )

    print_pass(f"{BACKEND_TO_STOP} stopped")


def check_failed_backend_is_unavailable():
    print()
    print(f"Checking that {BACKEND_TO_STOP} is unavailable...")

    result = run_command(
        [
            "docker",
            "inspect",
            "--format",
            "{{.State.Running}}",
            BACKEND_TO_STOP,
        ]
    )

    if result.lower() != "false":
        raise FailureTestError(
            f"{BACKEND_TO_STOP} is still running"
        )

    print_pass(
        f"{BACKEND_TO_STOP} is stopped and unavailable"
    )


def check_service_continues():
    print()
    print("Checking service availability during backend failure...")

    instances = []
    failures = 0

    for _ in range(TRAFFIC_REQUESTS):
        try:
            instance = get_instance()
            instances.append(instance)
        except FailureTestError:
            failures += 1

    observed = set(instances)

    if observed != {"app-02"}:
        raise FailureTestError(
            "traffic during failure did not consistently reach "
            f"the surviving backend: observed={sorted(observed)}"
        )

    if not instances:
        raise FailureTestError(
            "no successful requests reached the surviving backend"
        )

    print_pass(
        "service remained available through surviving backend: "
        f"app-02 ({len(instances)} successful requests)"
    )

    if failures:
        print(
            f"INFO  {failures} request(s) failed during "
            "backend failure"
        )


def restore_backend():
    print()
    print(f"Restoring {BACKEND_TO_STOP}...")

    run_command(
        ["docker", "compose", "start", BACKEND_TO_STOP]
    )

    print_pass(f"{BACKEND_TO_STOP} started")


def wait_for_recovery():
    print()
    print(
        f"Waiting up to {RECOVERY_TIMEOUT}s for "
        f"{BACKEND_TO_STOP} to become healthy..."
    )

    deadline = time.monotonic() + RECOVERY_TIMEOUT

    while time.monotonic() < deadline:
        try:
            health = run_command(
                [
                    "docker",
                    "inspect",
                    "--format",
                    "{{.State.Health.Status}}",
                    BACKEND_TO_STOP,
                ]
            )

            if health == "healthy":
                print_pass(
                    f"{BACKEND_TO_STOP} recovered and is healthy"
                )
                return

        except FailureTestError:
            pass

        time.sleep(1)

    raise FailureTestError(
        f"{BACKEND_TO_STOP} did not become healthy "
        f"within {RECOVERY_TIMEOUT}s"
    )


def verify_recovery():
    print()
    print("Verifying traffic after recovery...")

    deadline = time.monotonic() + RECOVERY_TIMEOUT
    observed = set()

    while time.monotonic() < deadline:
        instances = collect_instances(TRAFFIC_REQUESTS)
        observed.update(instances)

        if {"app-01", "app-02"}.issubset(observed):
            print_pass(
                "both backends serve traffic again after recovery: "
                f"{', '.join(sorted(observed))}"
            )
            return

        time.sleep(1)

    raise FailureTestError(
        "recovery verification failed: "
        f"observed={sorted(observed)}; "
        "both app-01 and app-02 were not observed"
    )


def main():
    print("=== BARQ Backend Failure Test ===")
    print(f"Target: {BASE_URL}")
    print(f"Backend under test: {BACKEND_TO_STOP}")
    print()

    stopped = False

    try:
        check_initial_state()

        stop_backend()
        stopped = True

        check_failed_backend_is_unavailable()
        check_service_continues()

    except FailureTestError as exc:
        print_fail(str(exc))

        # Always attempt to restore the backend before exiting.
        if stopped:
            try:
                restore_backend()
                wait_for_recovery()
            except FailureTestError as restore_exc:
                print_fail(
                    f"automatic restoration failed: {restore_exc}"
                )

        return 1

    try:
        restore_backend()
        stopped = False

        wait_for_recovery()
        verify_recovery()

    except FailureTestError as exc:
        print_fail(str(exc))

        # Best effort restoration if something went wrong.
        if stopped:
            try:
                restore_backend()
            except FailureTestError:
                pass

        return 1

    print()
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

