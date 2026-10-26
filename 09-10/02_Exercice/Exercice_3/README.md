```bash
docker build -t site-exercice-03 .

docker run -d --name site-exo3 -p 8090:80 site-exercice-03

curl -s http://localhost:8090

docker stop site-exo3
docker rm site-exo3
```
