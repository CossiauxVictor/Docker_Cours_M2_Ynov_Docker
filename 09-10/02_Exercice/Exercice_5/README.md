```bash
docker network create reseau-exo5
docker volume create mysql-data-exo5

docker run -d --name mysql-exo5 \
  --network reseau-exo5 \
  -v mysql-data-exo5:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=root_pw_exo5 \
  -e MYSQL_DATABASE=exo5db \
  -e MYSQL_USER=exo5user \
  -e MYSQL_PASSWORD=exo5pass \
  --restart unless-stopped \
  mysql:latest

docker run -d --name adminer-exo5 \
  --network reseau-exo5 \
  -p 8081:8080 \
  --restart unless-stopped \
  adminer

docker exec mysql-exo5 mysqladmin ping -uroot -proot_pw_exo5 --silent

docker run --rm --network reseau-exo5 mysql:latest \
  mysql -h mysql-exo5 -uexo5user -pexo5pass exo5db -e "
CREATE TABLE IF NOT EXISTS etudiants (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nom VARCHAR(100),
  formation VARCHAR(100)
);
INSERT INTO etudiants (nom, formation) VALUES ('Dupont', 'M2 Devops'), ('Martin', 'M2 Devops');
SELECT * FROM etudiants;
"

curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8081

docker rm -f mysql-exo5
docker run -d --name mysql-exo5 \
  --network reseau-exo5 \
  -v mysql-data-exo5:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=root_pw_exo5 \
  -e MYSQL_DATABASE=exo5db \
  -e MYSQL_USER=exo5user \
  -e MYSQL_PASSWORD=exo5pass \
  --restart unless-stopped \
  mysql:latest

docker exec mysql-exo5 mysql -uexo5user -pexo5pass exo5db -e "SELECT * FROM etudiants;"

docker exec mysql-exo5 mysqladmin shutdown -uroot -proot_pw_exo5

docker ps -a --filter name=mysql-exo5
docker inspect mysql-exo5 --format 'RestartCount={{.RestartCount}} Status={{.State.Status}}'

docker exec mysql-exo5 mysql -uexo5user -pexo5pass exo5db -e "SELECT * FROM etudiants;"
```

```bash
docker rm -f mysql-exo5 adminer-exo5
docker network rm reseau-exo5

docker compose up -d

docker exec mysql-exo5 mysql -uexo5user -pexo5pass exo5db -e "SELECT * FROM etudiants;"
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:8081

docker compose down
```
