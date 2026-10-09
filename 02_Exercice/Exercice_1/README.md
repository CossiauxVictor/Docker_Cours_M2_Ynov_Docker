```bash
docker run -dit --name ubuntu-nginx-exo ubuntu:latest bash

docker exec -it ubuntu-nginx-exo bash

apt-get update

apt-get install -y nginx

exit

docker commit ubuntu-nginx-exo ubuntu-nginx

docker images ubuntu-nginx
docker run --rm ubuntu-nginx nginx -v

docker stop ubuntu-nginx-exo
docker rm ubuntu-nginx-exo
```
