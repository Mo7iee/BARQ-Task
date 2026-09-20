## Entry — 2026-09-20 22:55
- Symptom:
    After starting the Docker Compose stack, `app-01` and `app-02`
    were running but reported as unhealthy. Requests through NGINX
    to `/` and `/health` failed with `curl: (56) Recv failure:
    Connection reset by peer`.

- Hypothesis:
    The Flask application containers may not be serving requests
    correctly, or NGINX may be unable to communicate with them.

- Command or test:
    ```bash
    docker ps
    curl -i http://127.0.0.1:8080/
    curl -i http://127.0.0.1:8080/health

- Actual output:
    app-01 and app-02 were unhealthy.
    45a13fb75384   barq-assessment-app-01   "python -m app.server"   19 seconds ago   Up 17 seconds (unhealthy)   8080/tcp                         app-01
    59523ec4af08   barq-assessment-app-02   "python -m app.server"   19 seconds ago   Up 17 seconds (unhealthy)   8080/tcp                         app-02

Failed attempt and what changed your thinking:
    No failed investigative attempt yet.

- Root cause:
    Not determined yet.

- Fix:
    Not determined yet.

- Retest evidence:
    Not performed yet.

- Related commit:
    524fb9d — chore: add starter baseline

- Remaining uncertainty:
    Need to determine whether the problem originates in the
    application containers, their healthchecks, or NGINX connectivity.

## Entry — 2026-09-20 23:26
- Symptom:
    After starting the Docker Compose stack, `app-01` and `app-02`
    were running but reported as unhealthy. Requests through NGINX
    to `/` and `/health` failed with `curl: (56) Recv failure:
    Connection reset by peer`.

- Hypothesis:
    The Flask application containers may not be serving requests
    correctly, or NGINX may be unable to communicate with them.

- Command or test:
    Inspected the application container logs:

    docker logs app-01

    The logs repeatedly showed:

    GET /healthz HTTP/1.1" 404

    Inspected the Flask application routes and found:

    @app.get("/health")
    def health():
        return response({"status": "alive"})

    There was no /healthz route.

- Actual output:
    The structured application logs also showed:
    {
    "level": "WARN",
    "event": "http_request",
    "path": "/healthz",
    "status": 404
    }

- Failed attempt and what changed your thinking:
    The initial hypothesis was that the Flask application might not be serving requests correctly.
    The application logs disproved this: Flask was successfully receiving the healthcheck requests and returning HTTP responses. The investigation therefore shifted toward a mismatch between the Docker healthcheck configuration and the application's actual health endpoint.

- Root cause:
    The Docker Compose healthcheck was configured incorrectly.

- Fix:
    Changed the application healthcheck in docker-compose.yml from /healthz to /health.

- Retest evidence:
    Restarted the application containers:

    docker compose up -d app-01 app-02

    Checked their status:

    docker ps

    Both application containers subsequently reported:

    app-01   Up ... (healthy)
    app-02   Up ... (healthy)

- Related commit:
    edbdbfe — fix: correct application healthcheck point

- Remaining uncertainty:
    The application healthcheck issue has been resolved and verified. Other initial connectivity failures, if still present, require separate investigation rather than being attributed to this issue.