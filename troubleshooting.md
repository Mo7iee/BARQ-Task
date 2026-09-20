## Entry — 2026-09-20 22:55 — Startup: apps unhealthy
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

## Entry — 2026-09-20 23:26 — Healthcheck mismatch (/healthz)
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

## Entry — 2026-09-20 23:59 —  Flask bind address issue

- Symptom:
    After correcting the application healthcheck endpoint, `app-01` and `app-02` reported as healthy, but there might be a network connectivity issue.
    ```
    curl -i http://127.0.0.1:8080/
    curl -i http://127.0.0.1:8080/health
    ```
    The requests continued to fail with:

    curl: (56) Recv failure: Connection reset by peer


- Hypothesis:
    The Flask applications were healthy inside their containers, but NGINX might not be able to reach the applications through the Docker network.
- Command or test:
    Inspected the application configuration in `docker-compose.yml` and found:
    ```
    environment: &app-env
    APP_HOST: "127.0.0.1"
    APP_PORT: "8080"
    ```
    Inspected the Flask startup code:
    ```
    create_app().run(
        host=os.getenv("APP_HOST", "0.0.0.0"),
        port=int(os.getenv("APP_PORT", "8080")),
        threaded=True,
        debug=False
    )
    ```
    This showed that Flask was explicitly configured to listen on `127.0.0.1` inside each application container.The application healthcheck also used:
    ```
    urllib.request.urlopen(
        'http://127.0.0.1:8080/health',
        timeout=2
    )
    ```
    Therefore, the healthcheck could succeed because it accessed Flask through the container's own loopback interface. NGINX, however, communicates with the application through the Docker network using the service name.

- Actual output:
    The application containers were healthy because their internal healthcheck could reach:
    ```
    127.0.0.1:8080
    ```
    However, Flask was not listening on the container's Docker network interface because it was bound to `127.0.0.1`.
- Failed attempt and what changed your thinking:
    The initial healthcheck investigation established that Flask was running and responding to requests inside the container.However, fixing the `/healthz` → `/health` mismatch did not restore connectivity through NGINX.This shifted the investigation from application health to the network interface on which Flask was listening.
- Root cause: 
    Flask was configured to bind to:
    ```
    127.0.0.1:8080
    ```
    inside the application containers.`127.0.0.1` refers to the container's loopback interface. NGINX reaches the application through the Docker network interface using the container/service name, so Flask needs to listen on an address that accepts connections through that interface.
- Fix:
    Changed the application host configuration from:
    ```
    APP_HOST: "127.0.0.1"
    ```
    to:
    ```
    APP_HOST: "0.0.0.0"
    ```
    This allows Flask to listen on all interfaces inside the container, including its Docker network interface.
- Retest evidence:
    Restarted the application containers:
    ```
    docker compose up -d app-01 app-02
    ```
    Verified their status:
    ```
    docker ps
    ```
    Verified the application through NGINX:
    ```
    curl -i http://127.0.0.1:8080/
    curl -i http://127.0.0.1:8080/health
    ```

- Related commit:
    edbdbfe — fix: correct application healthcheck point

- Remaining uncertainty: 
    This fix addresses Flask's bind address and NGINX-to-application connectivity. Other Docker networking and persistence issues identified in the starter configuration require separate investigation and verification.