# Security and Production-Readiness 

This review records concrete security and production-readiness risks in the final solution. It distinguishes between controls implemented in the assessment and improvements that would be appropriate for a production environment.

## 1. Secrets in Configuration Files
- **Risk and evidence**: Database credentials are required by the application, but committing the real config/app.env would expose secrets.
- Impact: Exposed credentials could allow unauthorized access to the database.
- Implemented fix / commit: config/app.env is excluded from Git. .env.example contains only non-sensitive example/CI values.
- Production follow-up: Use a secrets manager such as AWS Secrets Manager, Vault, or Kubernetes Secrets with appropriate access controls.
- **How to verify**: run git status and confirm the real environment file is not tracked. Review .gitignore and repository history.
## 2. Host Port Exposure
- **Risk and evidence**: Exposing PostgreSQL, Redis, or application ports directly would allow clients to bypass NGINX.
- **Impact**: Direct access could expose internal services and bypass the intended application entry point.
- **Implemented fix / commit**: Only NGINX publishes a host port (127.0.0.1:8080). PostgreSQL, Redis, and the Flask applications have no published host ports.
- **Production follow-up**: Bind public traffic only to the required load balancer or reverse proxy and keep internal services private.

- **How to verify**: Run:

    ```bash
    docker compose ps
    docker ps --format 'table {{.Names}}\t{{.Ports}}'
    ```

    and confirm only NGINX has a host port.

## 3. Container User
- **Risk and evidence**: Running an application process as root increases the potential impact of a container compromise.
- **Impact**: A vulnerability in the application could provide unnecessary privileges inside the container.
- **Implemented fix / commit**: The application container is designed to run with the minimum practical privileges.
- **Production follow-up**: Explicitly configure a dedicated non-root user in the Dockerfile and verify file permissions and package requirements.

- **How to verify**: Run:

    ```bash
    docker compose exec app-01 id
    ```

    and verify that the application is not running as root.

## 4. Container Image Selection
- **Risk and evidence**: Container images are part of the software supply chain and can contain vulnerabilities or unexpected changes.
- **Impact**: A compromised or vulnerable image could introduce security issues into the deployment.
- **Implemented fix / commit**: The Compose configuration uses specific image versions, with image digests pinned for the infrastructure images.
- **Production follow-up**: Regularly scan images for vulnerabilities, update dependencies, review image provenance, and rebuild images when security updates are released.
- **How to verify**: Run:

    ```bash
    docker compose config
    docker image inspect <image>
    ```

    and verify the expected image versions/digests.

## 5. Network Isolation
- **Risk and evidence**: Putting all containers on one network would allow NGINX to communicate directly with database and cache services.
- **Impact**: A compromised reverse proxy could potentially reach internal data services directly.
- **Implemented fix / commit**: Separate frontend and backend networks are used. NGINX is connected only to the frontend network, while PostgreSQL and Redis are connected only to the backend network.
- **Production follow-up**: Use security groups, private subnets, network policies, and least-privilege service-to-service communication.
- **How to verify**: Run:

    ```bash
    docker network inspect barq-assessment_frontend
    docker network inspect barq-assessment_backend
    ```

    and verify the expected container membership.

## 6. Database and Redis Persistence
- **Risk and evidence**: Container filesystems are temporary and can be lost when containers are removed.
- **Impact**: Application data could be lost during container recreation.
- **Implemented fix / commit**: PostgreSQL uses the named postgres-data volume and Redis uses the named redis-data volume with AOF persistence enabled.
- **Production follow-up**: Use managed database/cache services or dedicated persistent storage with defined retention and recovery policies.
- **How to verify**: Create a record, recreate the PostgreSQL container without removing volumes, and verify that the record still exists.
## 7. Backup and Restore
- **Risk and evidence**: Persistent storage alone does not protect against accidental deletion, corruption, or host-level failure.
- **Impact**: Data could become unrecoverable without an independent backup.
- **Implemented fix / commit**: backup.sh creates a PostgreSQL logical backup using pg_dump, and restore.sh restores the database from the generated SQL backup. Restore was tested successfully.
- **Production follow-up**: Store encrypted backups outside the host, use retention policies, automate backups, and regularly perform restore tests.

- **How to verify**: Run:

    ```bash
    ./backup.sh
    ```

    then restore the generated backup with:

    ```bash
    ./restore.sh backups/<backup-file>.sql
    ```

    and verify the expected records.

## 8. Logging and Monitoring
- Risk and evidence: Application failures and dependency problems require visibility to diagnose and respond to incidents.
- Impact: Without sufficient observability, failures can remain undetected or take longer to troubleshoot.
- Implemented fix / commit: The application provides health/readiness endpoints and structured request logging. Docker Compose logs can also be collected during CI failures.
- Production follow-up: Centralize logs and metrics and add monitoring, alerting, dashboards, and distributed tracing where required.

docker compose logs
- **How to verify**: Check:

    ```bash
    curl http://127.0.0.1:8080/health
    curl http://127.0.0.1:8080/ready
    docker compose logs
    ```
## 9. Service Availability
- **Risk and evidence**: The application has two instances, but NGINX and the Docker host remain single points of failure.
- **Impact**: Failure of the host or NGINX container can make both application instances unavailable.
- **Implemented fix / commit**: Two Flask instances run behind NGINX, and restart policies are configured for the containers.
- **Production follow-up**: Run multiple reverse-proxy/load-balancer instances or use a managed load balancer and deploy across multiple hosts or availability zones.
- **How to verify**: Stop one application instance and run the failure test. The remaining instance should continue serving requests, then the stopped instance should recover.
## 10. Resource Exhaustion
- **Risk and evidence**: A container without resource limits can consume excessive CPU or memory and affect other services on the host.
- **Impact**: Resource exhaustion could cause service degradation or container/host instability.
- **Implemented fix / commit**: CPU and memory limits are configured for the application, NGINX, PostgreSQL, and Redis containers.
- **Production follow-up**: Monitor actual resource usage and tune limits based on production workloads. Configure orchestrator-level requests and limits where applicable.

- **How to verify**: Run:

    ```bash
    docker stats
    ```

    and inspect the configured Compose resource limits.