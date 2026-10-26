```bash
docker network create reseau-exo4

docker run -dit --name conteneur1 ubuntu:latest bash

docker exec conteneur1 bash -c "apt-get update && apt-get install -y iputils-ping"

docker commit conteneur1 ubuntu-ping

docker run -dit --name conteneur2 --network reseau-exo4 ubuntu-ping bash

docker network connect reseau-exo4 conteneur1

docker network inspect reseau-exo4

docker exec conteneur1 ping -c 3 conteneur2

docker exec conteneur2 ping -c 3 conteneur1

docker stop conteneur1 conteneur2
docker rm conteneur1 conteneur2
docker network rm reseau-exo4
```
