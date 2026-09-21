#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACCESS_LOG="$ROOT_DIR/logs/access.log"
APP_LOG="$ROOT_DIR/logs/application.log"
ERROR_LOG="$ROOT_DIR/logs/error.log"

for file in "$ACCESS_LOG" "$APP_LOG" "$ERROR_LOG"; do
    if [[ ! -f "$file" ]]; then
        echo "FAIL: missing log file: $file" >&2
        exit 1
    fi
done

python3 - "$ACCESS_LOG" "$APP_LOG" "$ERROR_LOG" <<'PY'
import json
import math
import statistics
import sys
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path


ACCESS_PATH = Path(sys.argv[1])
APP_PATH = Path(sys.argv[2])
ERROR_PATH = Path(sys.argv[3])


# ============================================================
# Generic helpers
# ============================================================

def parse_timestamp(value):
    if not isinstance(value, str):
        raise ValueError("timestamp is not a string")

    value = value.replace("Z", "+00:00")
    timestamp = datetime.fromisoformat(value)

    if timestamp.tzinfo is None:
        raise ValueError("timestamp has no timezone")

    return timestamp.astimezone(timezone.utc)


def percentile(values, percentile_value):
    """
    Linear interpolation using:

        position = (n - 1) * p
    """

    if not values:
        return None

    ordered = sorted(values)

    if len(ordered) == 1:
        return ordered[0]

    position = (len(ordered) - 1) * percentile_value

    lower = math.floor(position)
    upper = math.ceil(position)

    if lower == upper:
        return ordered[lower]

    fraction = position - lower

    return ordered[lower] + (
        ordered[upper] - ordered[lower]
    ) * fraction


def print_section(title):
    print()
    print("=" * 70)
    print(title)
    print("=" * 70)


# ============================================================
# JSONL parsing
# ============================================================

def parse_jsonl(path, required_fields):
    records = []
    malformed = []
    duplicate_ids = []
    exact_duplicates = []

    seen_request_ids = set()
    seen_lines = set()

    with path.open("r", encoding="utf-8") as file:

        for line_number, raw_line in enumerate(file, start=1):

            line = raw_line.strip()

            if not line:
                continue

            if line in seen_lines:
                exact_duplicates.append(line_number)
            else:
                seen_lines.add(line)

            try:

                record = json.loads(line)

                if not isinstance(record, dict):
                    raise ValueError(
                        "JSON value is not an object"
                    )

                missing = [
                    field
                    for field in required_fields
                    if field not in record
                ]

                if missing:
                    raise ValueError(
                        f"missing fields: {', '.join(missing)}"
                    )

                request_id = record.get("request_id")

                if request_id in seen_request_ids:
                    duplicate_ids.append(
                        (line_number, request_id)
                    )
                else:
                    seen_request_ids.add(request_id)

                record["_line"] = line_number
                record["_timestamp"] = parse_timestamp(
                    record["timestamp"]
                )

                records.append(record)

            except Exception as exc:

                malformed.append(
                    {
                        "line": line_number,
                        "error": str(exc),
                        "raw": line,
                    }
                )

    return (
        records,
        malformed,
        duplicate_ids,
        exact_duplicates,
    )


# ============================================================
# NGINX error.log parsing
# ============================================================

def parse_error_log(path):

    records = []
    malformed = []
    notices = []
    duplicate_ids = []
    exact_duplicates = []

    seen_request_ids = set()
    seen_lines = set()

    with path.open("r", encoding="utf-8") as file:

        for line_number, raw_line in enumerate(file, start=1):

            line = raw_line.strip()

            if not line:
                continue

            # ------------------------------------------------
            # Exact duplicate
            # ------------------------------------------------

            if line in seen_lines:
                exact_duplicates.append(line_number)
            else:
                seen_lines.add(line)

            # ------------------------------------------------
            # Notice line
            # ------------------------------------------------

            if "[notice]" in line:

                match = re.match(
                    r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})",
                    line,
                )

                if match:

                    notices.append(
                        {
                            "line": line_number,
                            "timestamp": match.group(1),
                            "raw": line,
                        }
                    )

                    continue

            # ------------------------------------------------
            # Timestamp
            # ------------------------------------------------

            timestamp_match = re.match(
                r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})",
                line,
            )

            # ------------------------------------------------
            # Request ID
            # ------------------------------------------------

            request_id_match = re.search(
                r"request_id=([A-Za-z0-9_.:-]+)",
                line,
            )

            # ------------------------------------------------
            # Request
            # ------------------------------------------------

            request_match = re.search(
                r'request:\s+"([A-Z]+)\s+(\S+)\s+HTTP/[^"]+"',
                line,
            )

            # ------------------------------------------------
            # Upstream
            # ------------------------------------------------

            upstream_match = re.search(
                r'upstream:\s+"([^"]+)"',
                line,
            )

            # ------------------------------------------------
            # Error type
            # ------------------------------------------------

            if "connect() failed" in line:

                error_type = "connection_refused"

            elif "upstream timed out" in line:

                error_type = "upstream_timeout"

            else:

                error_type = None

            # ------------------------------------------------
            # Validate request-level error
            # ------------------------------------------------

            if (
                timestamp_match
                and request_id_match
                and request_match
                and upstream_match
                and error_type
            ):

                timestamp = datetime.strptime(
                    timestamp_match.group(1),
                    "%Y/%m/%d %H:%M:%S",
                ).replace(
                    tzinfo=timezone.utc
                )

                request_id = request_id_match.group(1)

                if request_id in seen_request_ids:

                    duplicate_ids.append(
                        (
                            line_number,
                            request_id,
                        )
                    )

                else:

                    seen_request_ids.add(
                        request_id
                    )

                records.append(
                    {
                        "timestamp": timestamp_match.group(1),
                        "level": "error",
                        "message": line,
                        "request_id": request_id,
                        "method": request_match.group(1),
                        "path": request_match.group(2),
                        "upstream": upstream_match.group(1),
                        "_line": line_number,
                        "_timestamp": timestamp,
                        "_error_type": error_type,
                    }
                )

                continue

            # ------------------------------------------------
            # Anything else is malformed
            # ------------------------------------------------

            malformed.append(
                {
                    "line": line_number,
                    "error": (
                        "line does not match expected "
                        "NGINX error format"
                    ),
                    "raw": line,
                }
            )

    return (
        records,
        malformed,
        duplicate_ids,
        exact_duplicates,
        notices,
    )


# ============================================================
# Load logs
# ============================================================

access_required = [
    "timestamp",
    "request_id",
    "method",
    "path",
    "status",
    "upstream",
    "upstream_status",
    "request_time",
    "client",
]

app_required = [
    "timestamp",
    "request_id",
    "instance_id",
    "method",
    "path",
    "status",
    "duration_ms",
]


(
    access,
    access_bad,
    access_duplicates,
    access_exact_duplicates,
) = parse_jsonl(
    ACCESS_PATH,
    access_required,
)


(
    application,
    app_bad,
    app_duplicates,
    app_exact_duplicates,
) = parse_jsonl(
    APP_PATH,
    app_required,
)


(
    errors,
    error_bad,
    error_duplicates,
    error_exact_duplicates,
    error_notices,
) = parse_error_log(
    ERROR_PATH
)


# ============================================================
# 1. LOG FILE VALIDATION
# ============================================================

print_section("1. LOG FILE VALIDATION")

for name, records, malformed, duplicates, exact_duplicates in [
    (
        "access.log",
        access,
        access_bad,
        access_duplicates,
        access_exact_duplicates,
    ),
    (
        "application.log",
        application,
        app_bad,
        app_duplicates,
        app_exact_duplicates,
    ),
    (
        "error.log",
        errors,
        error_bad,
        error_duplicates,
        error_exact_duplicates,
    ),
]:

    print(f"{name}:")

    print(
        f"  valid records:      {len(records)}"
    )

    print(
        f"  malformed lines:    {len(malformed)}"
    )

    print(
        f"  exact duplicates:   {len(exact_duplicates)}"
    )

    print(
        f"  duplicate IDs:      {len(duplicates)}"
    )

    if name == "error.log":

        print(
            f"  notice lines:       {len(error_notices)}"
        )

        connection_refused = sum(
            1
            for record in records
            if record["_error_type"]
            == "connection_refused"
        )

        upstream_timeouts = sum(
            1
            for record in records
            if record["_error_type"]
            == "upstream_timeout"
        )

        print(
            f"  connection refused: {connection_refused}"
        )

        print(
            f"  upstream timeouts:  {upstream_timeouts}"
        )


# ============================================================
# 2. UTC TIME COVERAGE
# ============================================================

print_section("2. UTC TIME COVERAGE")

all_timestamps = (
    [r["_timestamp"] for r in access]
    + [r["_timestamp"] for r in application]
    + [r["_timestamp"] for r in errors]
)


for notice in error_notices:

    timestamp = datetime.strptime(
        notice["timestamp"],
        "%Y/%m/%d %H:%M:%S",
    ).replace(
        tzinfo=timezone.utc
    )

    all_timestamps.append(timestamp)


if all_timestamps:

    print(
        "Overall interval:",
        min(all_timestamps).isoformat(),
        "to",
        max(all_timestamps).isoformat(),
    )


for name, records in [
    ("access.log", access),
    ("application.log", application),
    ("error.log", errors),
]:

    if records:

        timestamps = [
            r["_timestamp"]
            for r in records
        ]

        print(
            f"{name}:",
            min(timestamps).isoformat(),
            "to",
            max(timestamps).isoformat(),
        )


if error_notices:

    notice_timestamps = [
        datetime.strptime(
            notice["timestamp"],
            "%Y/%m/%d %H:%M:%S",
        ).replace(
            tzinfo=timezone.utc
        )
        for notice in error_notices
    ]

    print(
        "error.log notices:",
        min(notice_timestamps).isoformat(),
        "to",
        max(notice_timestamps).isoformat(),
    )


# ============================================================
# 3. DISTINCT CLIENT REQUESTS
# ============================================================

print_section("3. DISTINCT CLIENT REQUESTS")

access_by_id = {}

for record in access:

    request_id = record["request_id"]

    access_by_id.setdefault(
        request_id,
        record,
    )


distinct_requests = list(
    access_by_id.values()
)


print(
    f"Access-log records:       {len(access)}"
)

print(
    f"Distinct request IDs:     {len(distinct_requests)}"
)

print(
    f"Duplicate request IDs:    "
    f"{len(access) - len(distinct_requests)}"
)

print(
    f"Exact duplicate lines:    "
    f"{len(access_exact_duplicates)}"
)

print()

print(
    "Deduplication rule: "
    "request_id is treated as the unique identifier for one client request."
)

print(
    "Retry attempts are correlated to the same request_id rather than "
    "counted as additional client requests."
)


# ============================================================
# 4. CLIENT STATUS COUNTS
# ============================================================

print_section("4. CLIENT STATUS COUNTS AND ERROR RATE")

status_counts = Counter(
    record["status"]
    for record in distinct_requests
)


for status in sorted(status_counts):

    print(
        f"HTTP {status}: "
        f"{status_counts[status]}"
    )


total_requests = len(
    distinct_requests
)


server_error_requests = sum(
    count
    for status, count in status_counts.items()
    if int(status) >= 500
)


http_error_requests = sum(
    count
    for status, count in status_counts.items()
    if int(status) >= 400
)


server_error_rate = (
    server_error_requests
    / total_requests
    * 100
    if total_requests
    else 0
)


http_error_rate = (
    http_error_requests
    / total_requests
    * 100
    if total_requests
    else 0
)


print()

print(
    f"Total client requests: {total_requests}"
)

print(
    f"5xx client errors:     "
    f"{server_error_requests}"
)

print(
    f"5xx error rate:        "
    f"{server_error_rate:.2f}%"
)

print(
    f"4xx/5xx errors:        "
    f"{http_error_requests}"
)

print(
    f"4xx/5xx error rate:    "
    f"{http_error_rate:.2f}%"
)

print(
    "Denominator: all distinct client requests represented in access.log."
)


# ============================================================
# 5. FAILURE BREAKDOWN
# ============================================================

print_section("5. FAILURE BREAKDOWN")

failed_requests = [
    record
    for record in distinct_requests
    if int(record["status"]) >= 400
]


print(
    f"Total HTTP 4xx/5xx responses: "
    f"{len(failed_requests)}"
)


print()
print("Failures by path:")

for path, count in Counter(
    record["path"]
    for record in failed_requests
).most_common():

    print(
        f"  {path}: {count}"
    )


print()
print("Failures by final upstream:")

for upstream, count in Counter(
    record["upstream"]
    for record in failed_requests
).most_common():

    print(
        f"  {upstream}: {count}"
    )


print()
print("Failures by status:")

for status, count in Counter(
    record["status"]
    for record in failed_requests
).most_common():

    print(
        f"  HTTP {status}: {count}"
    )


failure_windows = Counter()


for record in failed_requests:

    timestamp = record["_timestamp"]

    minute = (
        timestamp.minute // 5
    ) * 5

    bucket = timestamp.replace(
        minute=minute,
        second=0,
        microsecond=0,
    )

    failure_windows[bucket] += 1


print()
print("Failures by 5-minute UTC window:")

for timestamp, count in sorted(
    failure_windows.items()
):

    print(
        f"  {timestamp.isoformat()} -> {count}"
    )


# ============================================================
# 6. CLIENT LATENCY
# ============================================================

print_section("6. CLIENT LATENCY")

latencies = [
    float(record["request_time"])
    for record in distinct_requests
]


if latencies:

    median = statistics.median(
        latencies
    )

    p95 = percentile(
        latencies,
        0.95,
    )

    print(
        f"Requests used: {len(latencies)}"
    )

    print(
        f"Median: {median * 1000:.3f} ms"
    )

    print(
        f"P95:    {p95 * 1000:.3f} ms"
    )

    print()

    print(
        "Percentile method: linear interpolation using the "
        "(n - 1) * p position in the sorted values."
    )

    print(
        "Input unit: seconds."
    )

    print(
        "Reported unit: milliseconds."
    )


# ============================================================
# 7. UPSTREAM RETRIES
# ============================================================

print_section("7. UPSTREAM RETRIES")

error_by_id = defaultdict(list)

for record in errors:

    error_by_id[
        record["request_id"]
    ].append(record)


error_ids = set(
    error_by_id
)


correlated_error_ids = (
    error_ids
    & set(access_by_id)
)


print(
    f"Requests with proxy error-log entries: "
    f"{len(error_ids)}"
)

print(
    f"Requests correlated to access.log:     "
    f"{len(correlated_error_ids)}"
)


def parse_attempted_upstreams(value):

    if not isinstance(value, str):
        return []

    return [
        item.strip()
        for item in value.split(",")
        if item.strip()
    ]


confirmed_retries = []


for request_id in sorted(
    correlated_error_ids
):

    record = access_by_id[
        request_id
    ]

    attempted_upstreams = parse_attempted_upstreams(
        record["upstream"]
    )

    unique_upstreams = list(
        dict.fromkeys(
            attempted_upstreams
        )
    )

    if len(unique_upstreams) > 1:

        confirmed_retries.append(
            request_id
        )


successful_retries = [
    request_id
    for request_id in confirmed_retries
    if int(
        access_by_id[
            request_id
        ]["status"]
    ) < 500
]


print()

print(
    f"Requests with evidence of upstream retry: "
    f"{len(confirmed_retries)}"
)

print(
    f"Retries that ultimately succeeded: "
    f"{len(successful_retries)}"
)


print()

print(
    "Retry interpretation:"
)

print(
    "  An error.log entry proves that NGINX experienced "
    "an upstream failure."
)

print(
    "  A matching access.log entry proves that the client "
    "request eventually received a final response."
)

print(
    "  Multiple upstream addresses for the same request_id "
    "provide evidence that NGINX attempted another upstream."
)


if confirmed_retries:

    print()
    print(
        "Requests with retry evidence:"
    )

    for request_id in confirmed_retries:

        record = access_by_id[
            request_id
        ]

        print(
            f"  {request_id}: "
            f"upstream={record['upstream']}, "
            f"final_status={record['status']}"
        )


# ============================================================
# 8. CROSS-LOG CORRELATION
# ============================================================

print_section("8. CROSS-LOG CORRELATION")

app_by_id = {
    record["request_id"]: record
    for record in application
}


access_ids = set(
    access_by_id
)

app_ids = set(
    app_by_id
)

error_ids = set(
    error_by_id
)


print(
    f"Distinct access IDs:       "
    f"{len(access_ids)}"
)

print(
    f"Distinct application IDs:  "
    f"{len(app_ids)}"
)

print(
    f"Distinct error-log IDs:     "
    f"{len(error_ids)}"
)


print()

print(
    "Access + application matches:",
    len(
        access_ids
        & app_ids
    ),
)

print(
    "Access + error matches:",
    len(
        access_ids
        & error_ids
    ),
)

print(
    "Application + error matches:",
    len(
        app_ids
        & error_ids
    ),
)


# ============================================================
# 9. CORRELATED EXAMPLES
# ============================================================

print_section("9. CORRELATED EXAMPLES")

failed_example = None


for request_id in sorted(
    error_ids
):

    if request_id in access_by_id:

        candidate = access_by_id[
            request_id
        ]

        if int(candidate["status"]) >= 500:

            failed_example = candidate

            break


if failed_example:

    request_id = failed_example[
        "request_id"
    ]

    print(
        "Failed/correlated example:"
    )

    print(
        f"  request_id: {request_id}"
    )

    print(
        f"  timestamp:  "
        f"{failed_example['_timestamp'].isoformat()}"
    )

    print(
        f"  request:    "
        f"{failed_example['method']} "
        f"{failed_example['path']}"
    )

    print(
        f"  status:     "
        f"{failed_example['status']}"
    )

    print(
        f"  upstream:   "
        f"{failed_example['upstream']}"
    )

    print(
        "  error.log:"
    )

    for error in error_by_id[
        request_id
    ]:

        print(
            f"    "
            f"{error['_timestamp'].isoformat()} "
            f"{error['_error_type']} "
            f"{error['upstream']}"
        )

    if request_id in app_by_id:

        print(
            "  application.log: "
            "request reached application"
        )

    else:

        print(
            "  application.log: "
            "no matching application record"
        )


successful_example = None


for request_id in successful_retries:

    candidate = access_by_id[
        request_id
    ]

    if int(candidate["status"]) == 200:

        successful_example = candidate

        break


if successful_example is None:

    successful_example = next(
        (
            record
            for record in distinct_requests
            if int(record["status"]) == 200
            and record["request_id"] in app_by_id
        ),
        None,
    )


if successful_example:

    request_id = successful_example[
        "request_id"
    ]

    print()

    print(
        "Successful/correlated example:"
    )

    print(
        f"  request_id: {request_id}"
    )

    print(
        f"  timestamp:  "
        f"{successful_example['_timestamp'].isoformat()}"
    )

    print(
        f"  request:    "
        f"{successful_example['method']} "
        f"{successful_example['path']}"
    )

    print(
        f"  status:     "
        f"{successful_example['status']}"
    )

    print(
        f"  upstream:   "
        f"{successful_example['upstream']}"
    )

    print(
        f"  application instance: "
        f"{app_by_id[request_id]['instance_id']}"
    )


# ============================================================
# 10. INCIDENT TIMELINE
# ============================================================

print_section("10. INCIDENT TIMELINE")

timeline = []


for record in errors:

    if record["_error_type"] == "connection_refused":

        message = (
            "connection refused to "
            f"{record['upstream']}"
        )

    else:

        message = (
            "upstream timeout while reading from "
            f"{record['upstream']}"
        )

    timeline.append(
        (
            record["_timestamp"],
            "NGINX error",
            record["request_id"],
            message,
        )
    )


for request_id in sorted(
    error_ids
):

    if request_id in access_by_id:

        record = access_by_id[
            request_id
        ]

        timeline.append(
            (
                record["_timestamp"],
                "Access log",
                request_id,
                (
                    f"{record['method']} "
                    f"{record['path']} "
                    f"-> HTTP {record['status']}"
                ),
            )
        )

    if request_id in app_by_id:

        record = app_by_id[
            request_id
        ]

        timeline.append(
            (
                record["_timestamp"],
                "Application log",
                request_id,
                (
                    f"{record['method']} "
                    f"{record['path']} "
                    f"-> HTTP {record['status']} "
                    f"on {record['instance_id']} "
                    f"({record['duration_ms']} ms)"
                ),
            )
        )


for timestamp, source, request_id, message in sorted(
    timeline
):

    print(
        f"{timestamp.isoformat()} | "
        f"{source:16} | "
        f"{request_id:12} | "
        f"{message}"
    )


# ============================================================
# 11. APPLICATION DEPENDENCY ERRORS
# ============================================================

print_section("11. APPLICATION DEPENDENCY ERRORS")

dependency_errors = Counter()


for record in application:

    if record.get("event") == "dependency_error":

        dependency = record.get(
            "dependency",
            "unknown",
        )

        error_type = record.get(
            "error_type",
            "unknown",
        )

        dependency_errors[
            (dependency, error_type)
        ] += 1


# Fallback: identify dependency records by the fields themselves.
# This keeps the analysis working even if the event field differs.
if not dependency_errors:

    for record in application:

        dependency = record.get(
            "dependency"
        )

        error_type = record.get(
            "error_type"
        )

        if dependency and error_type:

            dependency_errors[
                (dependency, error_type)
            ] += 1


if dependency_errors:

    for (dependency, error_type), count in sorted(
        dependency_errors.items()
    ):

        print(
            f"{dependency} | "
            f"{error_type}: "
            f"{count}"
        )

else:

    print(
        "No dependency_error records found."
    )


# ============================================================
# 12. /records APPLICATION LATENCY
# ============================================================

print_section("12. /records APPLICATION LATENCY")

records_durations = Counter()


for record in application:

    if (
        record.get("path") == "/records"
        and "duration_ms" in record
    ):

        try:

            duration = float(
                record["duration_ms"]
            )

            records_durations[
                duration
            ] += 1

        except (TypeError, ValueError):

            pass


if records_durations:

    for duration, count in sorted(
        records_durations.items()
    ):

        print(
            f"{duration:g} ms: {count}"
        )

else:

    print(
        "No /records duration data found."
    )


# ============================================================
# 13. INTERPRETATION AND LIMITS
# ============================================================

print_section("13. INTERPRETATION AND LIMITS")


connection_refused_count = sum(
    1
    for record in errors
    if record["_error_type"]
    == "connection_refused"
)


upstream_timeout_count = sum(
    1
    for record in errors
    if record["_error_type"]
    == "upstream_timeout"
)


print(
    "Proxy/connectivity evidence:"
)

print(
    f"  {connection_refused_count} NGINX error-log entries "
    "report connection refused while connecting to an upstream."
)


print()
print(
    "Proxy timeout evidence:"
)

print(
    f"  {upstream_timeout_count} NGINX error-log entries "
    "report upstream timeouts while reading the response header."
)


print()
print(
    "Application evidence:"
)

print(
    f"  {len(application)} application-log records "
    "show requests that reached the application layer."
)


print()
print(
    "Dependency evidence:"
)

if dependency_errors:

    for (dependency, error_type), count in sorted(
        dependency_errors.items()
    ):

        print(
            f"  {dependency}: "
            f"{error_type} "
            f"({count} records)"
        )

else:

    print(
        "  No dependency errors found."
    )


print()
print(
    "Important limitations:"
)

print(
    "  A connection-refused NGINX error does not by itself prove "
    "why the upstream refused the connection."
)

print(
    "  A dependency error does not by itself prove that it caused "
    "a later request failure unless timing and request correlation "
    "support that conclusion."
)

print(
    "  The /records 504 requests show application durations of "
    "2700 ms while NGINX returned 504 after approximately 2001 ms. "
    "This establishes a timeout mismatch, but does not establish "
    "why the application required 2700 ms."
)


print()
print(
    "Recommended next checks in the running environment:"
)

print(
    "  - docker compose ps"
)

print(
    "  - docker inspect <container>"
)

print(
    "  - docker logs <app-container>"
)

print(
    "  - container health status"
)

print(
    "  - ss -lntp inside the application container"
)

print(
    "  - Docker network connectivity and DNS"
)

print(
    "  - application readiness and dependency health"
)

print(
    "  - /records handler and database/dependency timing"
)

print(
    "  - NGINX proxy timeout configuration"
)


print()
print("=" * 70)
print("Analysis completed successfully.")
print("=" * 70)

PY