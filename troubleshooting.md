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

- Failed attempt and what changed your thinking:
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

## Entry — 2026-09-21 12:43 — NGINX port/upstream correction

- Symptom: 
    Requests to the application through NGINX were failing.

- Hypothesis:
    There was a port mismatch between the host-to-NGINX mapping and the ports NGINX was configured to listen on and proxy to.

- Command or test:
    Inspected `docker-compose.yml` and `nginx/nginx.conf` to compare the published NGINX port, NGINX listening port, and application upstream ports.

- Root cause:
    The NGINX port configuration was inconsistent. The NGINX container listens on port `80`, while the previous host mapping used an incorrect container port. Additionally, the upstream configuration referenced an incorrect application port for `app-01`.

- Fix: 
    Updated the NGINX host mapping to forward host port `8080` to container port `80`, and corrected both application upstreams to use port `8080`:
    ```
    ports:
    - "127.0.0.1:${PUBLIC_PORT:-8080}:80"
    ```

    ```
    upstream application_pool {
        server app-01:8080 max_fails=0;
        server app-02:8080 max_fails=0;
    }
    ```
- Retest evidence: 
    A direct request through NGINX returned `HTTP/1.1 200 OK`. Repeated requests to the `/` endpoint were then used to verify that both application instances receive traffic:
    ```
    for i in {1..10}; do
        curl -s http://127.0.0.1:8080/
        echo
    done
    ```
    The 10 requests returned: `app-01`: 5 requests - `app-02`: 5 requests

    Every request returned the expected application response:

    ```
    {
        "message": "Welcome to BARQ Systems",
        "service": "barq-api",
        "version": "2.0.0"
    }
    ```
    The `instance_id` field confirmed that traffic was successfully distributed across both backend instances.

- Related commit: Record the actual commit hash:
    7affbdd — fix: correct nginx port mappings

- Remaining uncertainty:
     None for the port-mapping and basic NGINX backend-distribution issue tested here.

## Entry — 2026-09-21 13:23 — PostgreSQL port issue

- Symptom:
    `After correcting the NGINX port and upstream configuration, the application was reachable through NGINX, but requests that required PostgreSQL returned HTTP 503.
    ```
    curl -i -X POST http://127.0.0.1:8080/records \
    -H 'Content-Type: application/json' \
    -d '{"title":"connection-test"}'
    ```
    The response was:
    ```
    HTTP/1.1 503 SERVICE UNAVAILABLE

    {"error":"postgres_unavailable","instance_id":"app-02","service":"barq-api","version":"2.0.0"}
    ```
`
- Hypothesis:
    The application may be configured with incorrect PostgreSQL and Redis ports for container-to-container communication.

- Command or test:    
    Inspected the Docker Compose service ports and application environment configuration. PostgreSQL listens on internal port `5432`, while Redis listens on internal port `6379`. The application environment was initially configured with:
    ```
    postgres:5433
    redis:6380
    ```
    Tested service discovery from `app-01`:
    ```
    getent hosts postgres
    getent hosts redis
    ```
    Result:
    ```
    172.19.0.5 postgres
    172.19.0.4 redis
    ```
    Tested TCP connectivity to the actual internal service ports:
    ```
    python -c "import socket; s=socket.create_connection(('postgres',5432),3); print('Postgres reachable'); s.close()"
    python -c "import socket; s=socket.create_connection(('redis',6379),3); print('Redis reachable'); s.close()"
    ```
    Result:
    ```
    Postgres reachable
    Redis reachable
    ```

- Actual output:
    The tests confirmed that Docker DNS and network connectivity were working, but the application endpoint still returned:
    ```
    HTTP/1.1 503 SERVICE UNAVAILABLE
    {"error":"postgres_unavailable",...}
    ```

- Failed attempt and what changed your thinking:
    The initial port mismatch was corrected by changing the application configuration to:
    ```
    DATABASE_URL=postgresql://barq_app:@postgres:5432/barq_tasks
    REDIS_URL=redis://redis:6379/0
    ```
    The containers were recreated and the environment variables were verified inside `app-01`. However, the PostgreSQL-dependent endpoint continued to return HTTP 503. This showed that correcting the ports resolved the network-level port issue but did not resolve the PostgreSQL connection problem.

- Root cause:
    The PostgreSQL port configuration was incorrect initially and was successfully corrected. After the port correction, a direct PostgreSQL connection using the application's `DATABASE_URL` produced:
    ```
    psycopg.OperationalError:
    connection failed: connection to server at "172.20.0.2", port 5432 failed:
    FATAL: password authentication failed for user "barq_app"
    ```
    This confirmed that the application can reach PostgreSQL on the correct port, but PostgreSQL is rejecting the supplied credentials.

- Fix: 
    Corrected the internal service ports:
    ```
    postgres:5433 → postgres:5432
    redis:6380    → redis:6379
    ```

- Retest evidence:
    After correcting the ports:
    ```
    curl -i http://127.0.0.1:8080/ready
    ```
    returned:
    ```
    HTTP/1.1 503 SERVICE UNAVAILABLE

    {"dependencies":{"postgres":"unavailable","redis":"ready"},
    "instance_id":"app-01",
    "service":"barq-api",
    "status":"not_ready",
    "version":"2.0.0"}
    ```
    This confirms:
    ```
    Redis:      ready
    PostgreSQL: unavailable
    ```
    A direct connection using the application's `DATABASE_URL` then confirmed:
    ```
    password authentication failed for user "barq_app"
    ```
    
- Related commit:
    0c91e13 — fix: use internal database and redis ports

- Remaining uncertainty:
    The PostgreSQL port issue has been resolved. The remaining issue is a PostgreSQL credential mismatch. It has not yet been determined whether the password in `config/app.env` is incorrect or whether PostgreSQL was initialized with a different password.

## Entry — 2026-09-21 14:59 — PostgreSQL credentials issue

- Symptom:
    `POST /records` was returning `503 SERVICE UNAVAILABLE` with:

    ```
    {"error":"postgres_unavailable","instance_id":"app-02","service":"barq-api","version":"2.0.0"}
    ```

- Hypothesis:
    The application might be using the wrong PostgreSQL and Redis ports inside the Docker network. The host-published ports (`15432` for PostgreSQL and `16379` for Redis) are different from the internal container ports (`5432` and `6379`).

- Command or test:
    First verified Docker service discovery from `app-01`:

    ```
    docker compose exec app-01 getent hosts postgres
    docker compose exec app-01 getent hosts redis
    ```

    Then verified TCP connectivity:

    ```
    docker compose exec app-01 python -c "import socket; s=socket.create_connection(('postgres',5432),3); print('Postgres reachable'); s.close()"
    docker compose exec app-01 python -c "import socket; s=socket.create_connection(('redis',6379),3); print('Redis reachable'); s.close()"
    ```

    Both hostname resolution and TCP connectivity succeeded.

    The application configuration initially contained incorrect internal ports:

    ```
    DATABASE_URL=postgresql://barq_app:@postgres:5433/barq_tasks
    REDIS_URL=redis://redis:6380/0
    ```

    The configuration was corrected to:

    ```
    DATABASE_URL=postgresql://barq_app:@postgres:5432/barq_tasks
    REDIS_URL=redis://redis:6379/0
    ```

- Actual output:
    After correcting the ports, `/records` still returned `503 SERVICE UNAVAILABLE`.

    `/ready` also reported:

    ```
    {"dependencies":{"postgres":"unavailable","redis":"ready"},"status":"not_ready"}
    ```

    A direct PostgreSQL connection using the application's actual `DATABASE_URL` was then tested:

    ```
    docker compose exec app-01 python -c "import psycopg, os; c=psycopg.connect(os.environ['DATABASE_URL'], connect_timeout=3); print('PostgreSQL authentication successful'); c.close()"
    ```

    The result was:

    ```
    FATAL: password authentication failed for user "barq_app"
    ```

- Failed attempt and what changed your thinking:
    Correcting the internal ports did not resolve the PostgreSQL failure. The successful TCP connection to `postgres:5432` showed that Docker DNS and network connectivity were working. The `psycopg` error specifically reported PostgreSQL authentication failure, so the investigation moved from networking to database credentials.

    A mismatch was then found between the PostgreSQL password configured in `docker-compose.yml` and the password contained in the application's `.env` configuration.

- Root cause:
    There were two configuration issues:

    1. The application initially used incorrect internal Docker ports:
       PostgreSQL: `5433` instead of `5432`
       Redis: `6380` instead of `6379`
    2. After correcting the ports, the PostgreSQL password in `.env` did not match the configured `barq_app` credentials.

- Fix:
    Updated the application database and Redis URLs to use the Docker-internal ports:

    ```
    postgres:5432
    redis:6379
    ```

    Then corrected the PostgreSQL password in `.env` so that it matched the configured `barq_app` credentials.

    The application containers were recreated to load the updated environment:

    ```
    docker compose up -d --force-recreate app-01 app-02
    ```

- Retest evidence:
    The application received the corrected database URL:

    ```
    postgresql://barq_app:***@postgres:5432/barq_tasks
    ```

    Direct PostgreSQL authentication succeeded:

    ```
    PostgreSQL authentication successful
    ```

    The readiness endpoint returned `200 OK`:

    ```
    {
      "dependencies": {
        "postgres": "ready",
        "redis": "ready"
      },
      "status": "ready"
    }
    ```

    Finally, the actual application operation succeeded:

    ```
    HTTP/1.1 201 CREATED
    ```

    The API created the record:

    ```
    {
      "record": {
        "id": 3,
        "title": "postgres-auth-fixed"
      }
    }
    ```

    This confirms the complete path from the application through Docker service discovery, PostgreSQL connectivity and authentication, to successful database insertion.

- Related commit:
    a3eab88 — fix: correct database credentials mismatch
  
- Remaining uncertainty:
    No remaining PostgreSQL connectivity or authentication issue was observed after the configuration corrections. The PostgreSQL and Redis dependencies both reported ready, and `POST /records` successfully created a database record.

## Entry — 2026-09-21 16:40 — PostgreSQL data persistence

- Symptom:
    A created database record needed to survive application and PostgreSQL container recreation as required by the assessment.

- Hypothesis:
    PostgreSQL data may not be persisted if the live PostgreSQL data directory is mounted on an ephemeral filesystem instead of a persistent Docker volume.

- Command or test:
    Inspected the PostgreSQL volume configuration in `docker-compose.yml`.

    The previous configuration used:

    ```
    volumes:
    - postgres-data:/var/lib/postgresql/backup
    ```

    and:

    ```
    tmpfs:
    - /var/lib/postgresql/data
    ```

    PostgreSQL stores its live database data under `/var/lib/postgresql/data`.

- Actual output:
    The named Docker volume was mounted at:

    ```
    /var/lib/postgresql/backup
    ```

    while the actual PostgreSQL data directory was mounted as:

    ```
    /var/lib/postgresql/data
    ```

    using `tmpfs`.

    This meant that the live database data was stored in an ephemeral filesystem rather than the named `postgres-data` volume.

- Failed attempt and what changed your thinking:
    The initial configuration appeared to define a PostgreSQL named volume, but inspection of the mount targets showed that the volume was not attached to PostgreSQL's actual data directory.

    The use of `tmpfs` on `/var/lib/postgresql/data` explained why database records did not survive PostgreSQL container recreation.

    This shifted the investigation from the existence of a named volume to verifying the exact directory where PostgreSQL stores its live data.

- Root cause:
    The PostgreSQL named volume was mounted at the incorrect path:

    ```
    /var/lib/postgresql/backup
    ```

    while the actual PostgreSQL data directory:

    ```
    /var/lib/postgresql/data
    ```

    was mounted as `tmpfs`.

    Therefore, PostgreSQL data was ephemeral and was lost when the PostgreSQL container was recreated.

- Fix:
    Changed the PostgreSQL volume configuration so that the named `postgres-data` volume is mounted directly at the PostgreSQL data directory:

    ```
    volumes:
    - postgres-data:/var/lib/postgresql/data
    - ./database/init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
    ```

    The `tmpfs` mount for `/var/lib/postgresql/data` was removed.

- Retest evidence:
    Created a new record through the application and verified that it existed in PostgreSQL.

    The application was then recreated together with the PostgreSQL container without deleting the named volume:

    ```
    docker compose up -d --force-recreate app-01 app-02 postgres
    ```

    PostgreSQL was queried again after the recreation and the previously created record was still present.

    This confirmed that the database record survived application and PostgreSQL container recreation.

- Related commit:
    2f32d28 — fix: persist PostgreSQL data across container recreation

- Remaining uncertainty:
    The test verifies persistence across container recreation while the named Docker volume remains intact.

    It does not verify recovery after deletion of the `postgres-data` volume, since deleting the volume would intentionally remove the persisted PostgreSQL data.