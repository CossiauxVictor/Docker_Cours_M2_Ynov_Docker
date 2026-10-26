```bash
docker compose up -d --build

curl -s http://localhost:8084/api/v1/dogs

curl -s -X POST http://localhost:8084/api/v1/dogs \
  -H "Content-Type: application/json" \
  -d '{"name":"Buddy","breed":"Corgi","birthDate":"2022-03-10","neutered":false}'

curl -s http://localhost:8084/api/v1/dogs

curl -s -w "\nHTTP %{http_code}\n" http://localhost:8084/api/v1/dogs/999

curl -s -o /dev/null -w "HTTP %{http_code}\n" -X PUT http://localhost:8084/api/v1/dogs/42 \
  -H "Content-Type: application/json" \
  -d '{"name":"x","breed":"x","birthDate":"2020-01-01","neutered":false}'

curl -s -o /dev/null -w "HTTP %{http_code}\n" -X DELETE http://localhost:8084/api/v1/dogs/42

docker run --rm --network exercice-9_reseau-exo9 curlimages/curl -s http://logs-api:8080/api/v1/logs

docker compose restart logs-api

docker run --rm --network exercice-9_reseau-exo9 curlimages/curl -s http://logs-api:8080/api/v1/logs

docker compose down
```
