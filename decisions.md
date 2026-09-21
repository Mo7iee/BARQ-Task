# Technical Decisions

This document records the main technical decisions made during the implementation, including assumptions, alternatives, trade-offs, and limitations.

## 1. Use a Python Alpine Base Image

* **Choice:** Use a lightweight Python Alpine image for the application.
* **Why:** Keeps the application image relatively small while providing the Python runtime required by Flask.
* **Alternative:** Use a Debian-based Python image.
* **Trade-off:** Alpine images are smaller, but some Python packages can be more difficult to build because of native dependencies.
* **Evidence / commit:** Application Dockerfile implementation.
* **Production improvement:** Use a pinned and regularly scanned base image and rebuild it regularly for security updates.

## 2. Use Container Health Checks

* **Choice:** Add Docker health checks to the application, PostgreSQL, and Redis containers.
* **Why:** Docker Compose can distinguish between a running container and a service that is actually ready.
* **Alternative:** Start all containers without health checks and rely only on startup order.
* **Trade-off:** Health checks add a small amount of configuration and periodic commands, but provide better readiness detection.
* **Evidence / commit:** `docker-compose.yml`.
* **Production improvement:** Use application-level readiness checks together with orchestration-level health monitoring.

## 3. Separate Frontend and Backend Networks

* **Choice:** Use separate `frontend` and `backend` Docker networks.
* **Why:** NGINX only needs access to the application containers, while PostgreSQL and Redis should only be reachable from the backend network.
* **Alternative:** Put all containers on one Docker network.
* **Trade-off:** Multiple networks add configuration complexity but provide network isolation.
* **Evidence / commit:** `docker-compose.yml` and `validate.py`.
* **Production improvement:** Use private subnets/security groups and stricter network policies in a production environment.

## 4. Use Service Names Instead of Container IPs

* **Choice:** Applications connect to `postgres` and `redis` using Docker Compose service names.
* **Why:** Container IP addresses can change when containers are recreated, while Docker DNS resolves service names automatically.
* **Alternative:** Configure fixed container IP addresses.
* **Trade-off:** Service-name resolution depends on the Docker network, but avoids managing dynamic IP addresses.
* **Evidence / commit:** Application configuration and `docker-compose.yml`.
* **Production improvement:** Use service discovery provided by the production orchestrator.

## 5. Add Timeouts and Readiness Retries

* **Choice:** Use short connection/operation timeouts in the application and bounded retries in validation.
* **Why:** Prevents failed dependencies from causing requests or validation to hang indefinitely.
* **Alternative:** Use unlimited retries or rely on default client timeouts.
* **Trade-off:** Short timeouts can cause failures during temporary network delays.
* **Evidence / commit:** Application dependency configuration and `validate.py`.
* **Production improvement:** Use carefully tuned retry policies with exponential backoff and circuit breakers where appropriate.

## 6. Use Restart Policies and Resource Limits

* **Choice:** Configure `restart: unless-stopped` and CPU/memory limits for the containers.
* **Why:** Allows services to recover from unexpected container failures while preventing a single service from consuming unlimited resources.
* **Alternative:** Use no restart policy or unlimited container resources.
* **Trade-off:** Automatic restarts can hide recurring application problems if monitoring is not available.
* **Evidence / commit:** `docker-compose.yml`.
* **Production improvement:** Use orchestrator resource requests/limits and centralized monitoring and alerting.

## 7. Use Named Volumes for Persistent Data

* **Choice:** Use named volumes for PostgreSQL and Redis data.
* **Why:** Container recreation should not remove application data.
* **Alternative:** Store database data only inside the container filesystem.
* **Trade-off:** Named volumes require explicit cleanup and backup procedures.
* **Evidence / commit:** `docker-compose.yml`, `backup.sh`, and `restore.sh`.
* **Production improvement:** Use managed PostgreSQL/Redis services or dedicated persistent storage with automated backups.

## 8. Use a Logical PostgreSQL Backup

* **Choice:** Use `pg_dump` to create a plain SQL backup.
* **Why:** The backup is simple to inspect and can be restored using standard PostgreSQL tools.
* **Alternative:** Use a physical PostgreSQL backup or managed database backups.
* **Trade-off:** Logical backups can take longer for large databases and do not provide the same physical-storage-level recovery characteristics as physical backups.
* **Evidence / commit:** `backup.sh` and `restore.sh`; restore was tested successfully.
* **Production improvement:** Use automated, encrypted, off-site backups with retention policies and regularly tested restore procedures.


