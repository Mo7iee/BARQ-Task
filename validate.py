#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request


BASE_URL = os.getenv("BASE_URL", "http://127.0.0.1:8080")
READY_TIMEOUT = int(os.getenv("READY_TIMEOUT", "30"))
REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "3"))
INSTANCE_REQUESTS = int(os.getenv("INSTANCE_REQUESTS", "10"))
EXPECTED_PUBLIC_PORT = int(
    os.getenv("EXPECTED_PUBLIC_PORT", "8080")
)


class ValidationError(Exception):
    pass


def pass_check(message):
    print(f"PASS  {message}")


def fail_check(message):
    print(f"FAIL  {message}")


def request(method, path, payload=None):
    url = f"{BASE_URL}{path}"

    data = None
    headers = {}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(
        url,
        data=data,
        headers=headers,
        method=method,
    )

    try:
        with urllib.request.urlopen(
            req,
            timeout=REQUEST_TIMEOUT,
        ) as response:
            body = response.read().decode("utf-8")
            return response.status, body

    except urllib.error.HTTPError as exc:
        body = exc.read().decode(
            "utf-8",
            errors="replace",
        )
        return exc.code, body

    except (
        urllib.error.URLError,
        TimeoutError,
        ConnectionError,
    ) as exc:
        raise ValidationError(
            f"{method} {path}: connection failed: {exc}"
        ) from exc


def wait_for_ready():
    deadline = time.monotonic() + READY_TIMEOUT

    print(
        f"Waiting up to {READY_TIMEOUT}s for "
        f"{BASE_URL}/ready ..."
    )

    while time.monotonic() < deadline:
        try:
            status, body = request("GET", "/ready")

            if status == 200:
                payload = json.loads(body)

                dependencies = payload.get(
                    "dependencies",
                    {},
                )

                if (
                    dependencies.get("postgres") == "ready"
                    and dependencies.get("redis") == "ready"
                ):
                    pass_check(
                        "/ready → PostgreSQL and Redis ready"
                    )
                    return

        except (
            ValidationError,
            json.JSONDecodeError,
        ):
            pass

        time.sleep(1)

    raise ValidationError(
        f"/ready did not report PostgreSQL and Redis "
        f"as ready within {READY_TIMEOUT}s"
    )


def check_basic_endpoints():
    # /
    status, body = request("GET", "/")

    if status != 200:
        raise ValidationError(
            f"/ → expected 200, got {status}"
        )

    payload = json.loads(body)

    if payload.get("service") != "barq-api":
        raise ValidationError(
            "/ → unexpected service name"
        )

    pass_check("/ → HTTP 200")

    # /health
    status, body = request("GET", "/health")

    if status != 200:
        raise ValidationError(
            f"/health → expected 200, got {status}"
        )

    payload = json.loads(body)

    if payload.get("status") != "alive":
        raise ValidationError(
            f"/health → unexpected status: {payload}"
        )

    pass_check("/health → alive")

    # /ready
    status, body = request("GET", "/ready")

    if status != 200:
        raise ValidationError(
            f"/ready → expected 200, got {status}"
        )

    pass_check("/ready → HTTP 200")


def check_instances():
    instances = set()

    for _ in range(INSTANCE_REQUESTS):
        status, body = request(
            "GET",
            "/instance",
        )

        if status != 200:
            raise ValidationError(
                f"/instance → expected 200, got {status}"
            )

        payload = json.loads(body)

        instance_id = payload.get("instance_id")

        if instance_id:
            instances.add(instance_id)

    required = {
        "app-01",
        "app-02",
    }

    missing = required - instances

    if missing:
        raise ValidationError(
            "not all backends were observed; "
            f"observed={sorted(instances)}, "
            f"missing={sorted(missing)}"
        )

    pass_check(
        "both backends observed through NGINX: "
        f"{', '.join(sorted(instances))}"
    )


def check_records():
    title = f"validation-{int(time.time())}"

    # Create record
    status, body = request(
        "POST",
        "/records",
        {"title": title},
    )

    if status != 201:
        raise ValidationError(
            "POST /records → expected 201, "
            f"got {status}: {body}"
        )

    payload = json.loads(body)
    record = payload.get("record")

    if not isinstance(record, dict):
        raise ValidationError(
            "POST /records → response did not "
            "contain a record"
        )

    if record.get("title") != title:
        raise ValidationError(
            "POST /records → returned title "
            "does not match"
        )

    record_id = record.get("id")

    if not isinstance(record_id, int):
        raise ValidationError(
            "POST /records → returned record "
            "has no valid id"
        )

    pass_check(
        "POST /records → created PostgreSQL "
        f"record id={record_id}"
    )

    # Retrieve record
    status, body = request(
        "GET",
        "/records",
    )

    if status != 200:
        raise ValidationError(
            "GET /records → expected 200, "
            f"got {status}"
        )

    payload = json.loads(body)
    records = payload.get("records", [])

    matching = [
        record
        for record in records
        if (
            record.get("id") == record_id
            and record.get("title") == title
        )
    ]

    if not matching:
        raise ValidationError(
            "created record "
            f"id={record_id} was not returned "
            "by GET /records"
        )

    pass_check(
        "GET /records → created record "
        f"id={record_id} persisted"
    )


def check_counter():
    # First request
    status, body = request(
        "GET",
        "/counter",
    )

    if status != 200:
        raise ValidationError(
            "/counter → expected 200, "
            f"got {status}"
        )

    payload = json.loads(body)
    first = payload.get("counter")

    if not isinstance(first, int):
        raise ValidationError(
            f"/counter → invalid counter value: "
            f"{payload}"
        )

    # Second request
    status, body = request(
        "GET",
        "/counter",
    )

    if status != 200:
        raise ValidationError(
            "/counter second request → expected 200, "
            f"got {status}"
        )

    payload = json.loads(body)
    second = payload.get("counter")

    if not isinstance(second, int):
        raise ValidationError(
            "/counter second request → invalid value: "
            f"{payload}"
        )

    if second <= first:
        raise ValidationError(
            "Redis counter did not increment: "
            f"{first} → {second}"
        )

    pass_check(
        "/counter → Redis counter incremented: "
        f"{first} → {second}"
    )


def check_published_ports():
    try:
        result = subprocess.run(
            [
                "docker",
                "compose",
                "ps",
                "--format",
                "json",
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    except subprocess.CalledProcessError as exc:
        raise ValidationError(
            f"docker compose ps failed: {exc}"
        ) from exc

    services = []

    for line in result.stdout.splitlines():
        line = line.strip()

        if not line:
            continue

        try:
            services.append(json.loads(line))

        except json.JSONDecodeError as exc:
            raise ValidationError(
                "could not parse docker compose ps output"
            ) from exc

    expected = {
        "nginx",
        "app-01",
        "app-02",
        "postgres",
        "redis",
    }

    found = {
        service.get("Service")
        for service in services
    }

    missing = expected - found

    if missing:
        raise ValidationError(
            f"missing services: {sorted(missing)}"
        )

    for service in services:
        name = service.get("Service")

        publishers = service.get(
            "Publishers"
        ) or []

        # Docker Compose can report internal container
        # ports with PublishedPort=0. These are NOT
        # host-published ports.
        published_ports = {
            int(port.get("PublishedPort"))
            for port in publishers
            if (
                isinstance(port, dict)
                and port.get("PublishedPort") is not None
                and int(port.get("PublishedPort") or 0) > 0
            )
        }

        if name == "nginx":
            if EXPECTED_PUBLIC_PORT not in published_ports:
                raise ValidationError(
                    "NGINX does not publish expected "
                    f"host port {EXPECTED_PUBLIC_PORT}: "
                    f"{publishers}"
                )

            pass_check(
                "NGINX publishes host port "
                f"{EXPECTED_PUBLIC_PORT}"
            )

        else:
            if published_ports:
                raise ValidationError(
                    f"{name} has published host ports: "
                    f"{sorted(published_ports)}"
                )

            pass_check(
                f"{name} has no published host ports"
            )


def run_check(name, function):
    try:
        function()
        return True

    except (
        ValidationError,
        json.JSONDecodeError,
        KeyError,
        ValueError,
    ) as exc:
        fail_check(
            f"{name}: {exc}"
        )
        return False


def main():
    print(
        "=== BARQ Environment Validation ==="
    )
    print(
        f"Target: {BASE_URL}"
    )
    print()

    checks = [
        (
            "readiness",
            wait_for_ready,
        ),
        (
            "basic endpoints",
            check_basic_endpoints,
        ),
        (
            "backend instances",
            check_instances,
        ),
        (
            "PostgreSQL records",
            check_records,
        ),
        (
            "Redis counter",
            check_counter,
        ),
        (
            "published ports",
            check_published_ports,
        ),
    ]

    failures = 0

    for name, function in checks:
        if not run_check(
            name,
            function,
        ):
            failures += 1

    print()

    if failures:
        print(
            f"RESULT: FAIL ({failures} check(s) failed)"
        )
        return 1

    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

