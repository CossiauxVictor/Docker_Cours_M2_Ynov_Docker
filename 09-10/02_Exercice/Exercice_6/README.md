```bash
docker run -d --name nginx-dev-exo6 \
  -p 8082:80 \
  -v "$(pwd)/site:/usr/share/nginx/html" \
  nginx:latest

curl -s http://localhost:8082

docker stop nginx-dev-exo6
docker rm nginx-dev-exo6
```
