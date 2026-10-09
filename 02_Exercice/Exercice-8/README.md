```bash
docker network create reseau-exo8

docker run -d --name mysql-exo8 \
  --network reseau-exo8 \
  -e MYSQL_ROOT_PASSWORD=root_pw_exo8 \
  -e MYSQL_DATABASE=dogsdb \
  -e MYSQL_USER=dogsuser \
  -e MYSQL_PASSWORD=dogspass \
  -p 3308:3306 \
  mysql:latest

cd kennel-api
docker build -t kennel-api .

docker run -d --name kennel-api-exo8 \
  --network reseau-exo8 \
  -e DB_HOST=mysql-exo8 \
  -e DB_PORT=3306 \
  -e DB_NAME=dogsdb \
  -e DB_USER=dogsuser \
  -e DB_PASSWORD=dogspass \
  -p 8083:8080 \
  kennel-api

curl -s http://localhost:8083/api/v1/dogs

curl -s -X POST http://localhost:8083/api/v1/dogs \
  -H "Content-Type: application/json" \
  -d '{"name":"Rex","breed":"Labrador","birthDate":"2020-01-01","neutered":true}'

curl -s -X POST http://localhost:8083/api/v1/dogs \
  -H "Content-Type: application/json" \
  -d '{"name":"Milo","breed":"Beagle","birthDate":"2021-06-15","neutered":false}'

curl -s http://localhost:8083/api/v1/dogs

curl -s http://localhost:8083/api/v1/dogs/1

curl -s -X PUT http://localhost:8083/api/v1/dogs/1 \
  -H "Content-Type: application/json" \
  -d '{"name":"Rex","breed":"Labrador","birthDate":"2020-01-01","neutered":false}'

curl -s -X DELETE http://localhost:8083/api/v1/dogs/2

curl -s http://localhost:8083/api/v1/dogs

curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8083/api/v1/dogs/999

docker stop kennel-api-exo8 mysql-exo8
docker rm kennel-api-exo8 mysql-exo8
docker network rm reseau-exo8
```
