Log analysis
Commands / scripts

The analysis was performed with the Bash/Python script:

chmod +x logscript/analyze_logs.sh
./logscript/analyze_logs.sh

The script reads:

logs/access.log
logs/application.log
logs/error.log

It validates records, detects duplicates, calculates status/error rates and latency percentiles, correlates request IDs between logs, identifies upstream retries, and builds the incident timeline.

Results
1. UTC interval and log validation

Overall UTC interval:

2026-08-20T11:00:00.015000+00:00
to
2026-08-20T11:30:00+00:00
Log	Valid	Malformed	Duplicate
access.log	725	1	5
application.log	682	48	2
error.log	67	0	0

The error log also contains:

Connection refused: 59
Upstream timeouts: 8
Notice lines: 1

The five duplicate access records and two duplicate application records were detected using their request_id values. Exact duplicate lines were also checked.

2. Distinct client requests

There were:

725 access-log records
720 distinct request IDs
5 duplicate request IDs

request_id was used as the unique identifier for a client request.

Retries were not counted as new client requests because an upstream retry keeps the same request_id. For example, lab-000124 has two upstream addresses but represents one client request.

Therefore, the number of distinct client requests is:

720
3. Final client status counts and error rate
HTTP 200: 615
HTTP 404: 10
HTTP 502: 40
HTTP 503: 47
HTTP 504: 8

Total:

720 distinct client requests

5xx errors:

95

5xx error rate:

95 / 720 = 13.19%

Including both 4xx and 5xx:

105 / 720 = 14.58%

The denominator is all 720 distinct client requests represented in access.log.

4. Failure breakdown

There were 105 final 4xx/5xx responses.

By path:

/records: 26
/counter: 26
/ready: 23
/missing: 10
/health: 10
/: 10

By final upstream:

172.23.0.12:8080: 73
172.23.0.11:8080: 32

By status:

503: 47
502: 40
404: 10
504: 8

By 5-minute UTC window:

11:00-11:04: 2
11:05-11:09: 42
11:10-11:14: 24
11:15-11:19: 10
11:20-11:24: 17
11:25-11:29: 10

The largest concentration of failures occurred during the 11:05-11:09 window, when NGINX repeatedly reported connection refusals to 172.23.0.12:8080.

5. Client latency

Using the 720 distinct client requests:

Median: 54.000 ms
P95:    2001.000 ms

The percentile calculation uses linear interpolation with:

(n - 1) * p

where p is the percentile.

The original latency values were in seconds and were converted to milliseconds for reporting.

6. Upstream retries

There were:

67 requests with NGINX error-log entries
67 correlated with access.log
19 requests with evidence of an upstream retry
19 retries ultimately succeeded

A retry was identified when the same request_id had:

an upstream failure in error.log, and
multiple upstream addresses in access.log.

For example:

lab-000124
upstream: 172.23.0.12:8080, 172.23.0.11:8080
final status: 200

This indicates that NGINX failed to connect to the first upstream and then successfully used the second upstream.

Timeline and correlated examples
7. Incident timeline

11:00–11:04 UTC — Normal baseline

Requests were generally successful with HTTP 200 responses.

11:05–11:09 UTC — Upstream connectivity failures

NGINX recorded 59 connection refused errors while connecting to:

172.23.0.12:8080

The errors occurred repeatedly across different endpoints.

Some requests returned 502 directly, while 19 requests retried against 172.23.0.11:8080 and eventually returned 200.

11:12–11:15 UTC — Redis dependency errors

Application logs contain:

redis | TimeoutError | 31

These errors occurred on the application layer and indicate Redis timeout problems.

11:20–11:21 UTC — PostgreSQL dependency errors

Application logs contain:

postgres | InvalidPassword | 16

These indicate PostgreSQL authentication/configuration errors at the application dependency layer.

11:25–11:26 UTC — /records timeout

Eight /records requests returned HTTP 504.

The application logs show the same requests completed with:

HTTP 200
duration: 2700 ms

while NGINX returned the client response after approximately:

2001 ms

This indicates that the application took longer than the NGINX timeout.

11:30 UTC — Log rotation

The error log contains a notice indicating that the log collector rotated the stream.

8. Correlated examples
Failed request
request_id: lab-000122
timestamp: 2026-08-20T11:05:02.503000+00:00
request: GET /health
status: HTTP 502
upstream: 172.23.0.12:8080

Corresponding NGINX error:

2026-08-20T11:05:02+00:00
connection refused
http://172.23.0.12:8080/health

There is no matching application record for this request, which supports the conclusion that the request failed before reaching the application.

Successful request after retry
request_id: lab-000124
timestamp: 2026-08-20T11:05:07.620000+00:00
request: GET /ready
status: HTTP 200
upstream: 172.23.0.12:8080, 172.23.0.11:8080
application instance: app-01

The NGINX error log shows a connection refusal to the first upstream:

2026-08-20T11:05:07+00:00
connection refused
http://172.23.0.12:8080/ready

The access log then shows a successful response using both upstreams, providing evidence of a successful retry.

Conclusions and limits
9. Proxy/connectivity vs dependency/application issues

Proxy/upstream connectivity issue:

The 59 NGINX errors containing:

connect() failed
Connection refused

show that NGINX could not establish a connection to 172.23.0.12:8080.

The absence of a corresponding application record for requests such as lab-000122 also supports the conclusion that those requests failed before reaching the application.

Application dependency issues:

The application log explicitly reports:

Redis TimeoutError: 31
PostgreSQL InvalidPassword: 16

These are application-level dependency errors.

Application/proxy timeout issue:

The eight /records requests show:

Application duration: 2700 ms
NGINX/client result: HTTP 504 after approximately 2001 ms

This proves that the application processing time exceeded the NGINX timeout for these requests.

10. What the logs do not prove

The logs do not prove the exact root cause of the connection refusals. They show that the connection was refused, but not whether this was caused by:

an application process being down,
a container restart,
a listener problem,
a networking problem,
or another infrastructure issue.

The Redis and PostgreSQL errors also do not automatically prove that they caused a particular client failure without additional request and timing correlation.

For the /records timeout, the logs prove that the application took approximately 2700 ms and NGINX timed out at approximately 2001 ms, but they do not explain why /records took 2700 ms.