```bash
docker build -t kennel-mysql .

docker run -d --name kennel-mysql-exo7 -e MYSQL_ROOT_PASSWORD=root_pw_exo7 -p 3307:3306 kennel-mysql

docker exec kennel-mysql-exo7 mysqladmin ping -uroot -proot_pw_exo7 --silent

docker exec kennel-mysql-exo7 mysql -uroot -proot_pw_exo7 -e "
USE kennelDB;
SHOW TABLES;
SELECT * FROM clients;
SELECT * FROM adresses;
SELECT * FROM clients_adresses;
SELECT * FROM chiens;
SELECT * FROM chats;
"

docker stop kennel-mysql-exo7
docker rm kennel-mysql-exo7
```
