# Testing Indvidual Endpoints
curl http://localhost:8080/
curl http://localhost:8080/health
curl http://localhost:8080/ready
curl http://localhost:8080/records
curl http://localhost:8080/counter

# Testing Nginx Load Balancing
for i in {1..10}; do curl -s http://localhost:8080/instance; echo; done

# Create a new record 
curl -i -X POST http://localhost:8080/records \
  -H "Content-Type: application/json" \
  -d '{"title":"persistence-test"}'

# Testing DB Connection and Tables
docker compose exec postgres psql -U barq_app -d barq_tasks \
  -c "SELECT * FROM records;"

# Container Recreation
docker compose up -d --force-recreate

# Stop one app
docker compose stop app-02

# Show NGINX errors
docker compose logs --tail=50 nginx

# Start the app again
docker compose start app-02

# Test after creating 3rd instance 
for i in {1..15}; do curl -s http://localhost:8090/instance; echo; done

# NGINX Logs Commands
grep -i "connect() failed.*Connection refused.*while connecting to upstream" logs/error.log
grep -i "connect() failed.*Connection refused.*while connecting to upstream" logs/error.log | grep -ic "connection refused"

grep -i "connection refused" logs/error.log | head -1
grep -i "connection refused" logs/error.log | tail -1

grep -i "connect() failed.*Connection refused.*while connecting to upstream" logs/error.log   | cut -d' ' -f1,2 | cut -d: -f1-2 | sort | uniq -c