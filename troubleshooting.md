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

