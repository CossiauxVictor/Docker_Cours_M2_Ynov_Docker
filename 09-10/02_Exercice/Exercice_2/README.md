```bash
docker pull kubespheredev/2048

docker run -d --name jeu-2048 -p 8080:80 kubespheredev/2048

curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8080

docker stop jeu-2048
docker rm jeu-2048
```
